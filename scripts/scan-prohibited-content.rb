#!/usr/bin/env ruby
# frozen_string_literal: true

require "zlib"

class ScanFailure < StandardError; end

class ArtifactScanner
  MAX_FILE_BYTES = Integer(ENV.fetch("LIMITBAR_SCAN_MAX_FILE_BYTES", 64 * 1024 * 1024))
  MAX_ZIP_COMPRESSED_BYTES = Integer(ENV.fetch("LIMITBAR_SCAN_MAX_ZIP_COMPRESSED_BYTES", 64 * 1024 * 1024))
  MAX_ZIP_MEMBERS = Integer(ENV.fetch("LIMITBAR_SCAN_MAX_ZIP_MEMBERS", 1_000))
  MAX_MEMBER_BYTES = Integer(ENV.fetch("LIMITBAR_SCAN_MAX_MEMBER_BYTES", 16 * 1024 * 1024))
  MAX_TOTAL_MEMBER_BYTES = Integer(ENV.fetch("LIMITBAR_SCAN_MAX_TOTAL_MEMBER_BYTES", 64 * 1024 * 1024))
  MAX_COMPRESSION_RATIO = Float(ENV.fetch("LIMITBAR_SCAN_MAX_COMPRESSION_RATIO", 100))
  ZIP_SIGNATURES = ["PK\x03\x04", "PK\x05\x06", "PK\x07\x08"].map(&:b).freeze
  PROHIBITED = %r{(/Users/[^/<\s]+|/home/[^/<\s]+|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9_-]{20,}|Bearer\s+[A-Za-z0-9._~+/\-]{20,})}

  def initialize(sentinels)
    @sentinels = sentinels
  end

  def scan_roots(roots)
    raise ScanFailure, "no artifact roots supplied" if roots.empty?
    roots.each { |root| scan_root(root) }
  end

  private

  def scan_root(path)
    stat = File.lstat(path)
    raise ScanFailure, "symlink artifact root: #{path}" if stat.symlink?
    if stat.file?
      scan_file(path, stat)
    elsif stat.directory?
      scan_directory(path)
    else
      raise ScanFailure, "unsupported artifact root type: #{path}"
    end
  rescue Errno::ENOENT, Errno::EACCES => error
    raise ScanFailure, "unavailable artifact root: #{path} (#{error.class})"
  end

  def scan_directory(root)
    Dir.each_child(root) do |name|
      path = File.join(root, name)
      stat = File.lstat(path)
      raise ScanFailure, "symlink encountered: #{path}" if stat.symlink?
      if stat.directory?
        scan_directory(path)
      elsif stat.file?
        scan_file(path, stat)
      else
        raise ScanFailure, "unsupported artifact encountered: #{path}"
      end
    end
  rescue Errno::EACCES => error
    raise ScanFailure, "unreadable artifact directory: #{root} (#{error.class})"
  end

  def scan_file(path, stat)
    raise ScanFailure, "artifact exceeds byte limit: #{path}" if stat.size > MAX_FILE_BYTES
    raise ScanFailure, "unreadable artifact: #{path}" unless File.readable?(path)
    flags = File::RDONLY
    flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
    data = File.open(path, flags) do |file|
      opened = file.stat
      raise ScanFailure, "artifact changed type while opening: #{path}" unless opened.file? && opened.dev == stat.dev && opened.ino == stat.ino
      file.read(MAX_FILE_BYTES + 1)
    end
    raise ScanFailure, "artifact changed or exceeds byte limit: #{path}" unless data.bytesize == stat.size && data.bytesize <= MAX_FILE_BYTES
    if path.downcase.end_with?(".zip") || ZIP_SIGNATURES.any? { |signature| data.start_with?(signature) }
      scan_zip(path, data)
    else
      scan_bytes(path, data)
    end
  rescue Errno::EACCES, Errno::EIO => error
    raise ScanFailure, "unreadable artifact: #{path} (#{error.class})"
  end

  def scan_bytes(label, data)
    strings = data.scan(/[\x20-\x7e]{4,}/n)
    strings.concat(utf16_strings(data, little_endian: true))
    strings.concat(utf16_strings(data, little_endian: false))
    strings << data.dup.force_encoding(Encoding::UTF_8).scrub
    strings.each do |string|
      text = string.dup.force_encoding(Encoding::UTF_8).scrub
      raise ScanFailure, "prohibited private-path or credential-shaped content in #{label}" if text.match?(PROHIBITED)
      raise ScanFailure, "prohibited sentinel in #{label}" if @sentinels.any? { |sentinel| text.include?(sentinel) }
    end
  end

  def utf16_strings(data, little_endian:)
    results = []
    [0, 1].each do |alignment|
      current = +""
      index = alignment
      while index + 1 < data.bytesize
        first = data.getbyte(index)
        second = data.getbyte(index + 1)
        character = if little_endian && second.zero? && first.between?(0x20, 0x7e)
                      first
                    elsif !little_endian && first.zero? && second.between?(0x20, 0x7e)
                      second
                    end
        if character
          current << character
        else
          results << current.dup if current.bytesize >= 4
          current.clear
        end
        index += 2
      end
      results << current.dup if current.bytesize >= 4
    end
    results
  end

  def scan_zip(label, data)
    raise ScanFailure, "ZIP compressed byte limit exceeded: #{label}" if data.bytesize > MAX_ZIP_COMPRESSED_BYTES
    raise ScanFailure, "ZIP64 is unsupported: #{label}" if data.include?("PK\x06\x06".b) || data.include?("PK\x06\x07".b)
    scan_bytes("#{label} metadata", data)
    eocd_offset = find_eocd(data)
    eocd = data.byteslice(eocd_offset, 22).unpack("VvvvvVVv")
    _, disk, central_disk, disk_entries, entries, central_size, central_offset, comment_size = eocd
    raise ScanFailure, "multi-disk or ZIP64 archive unsupported: #{label}" unless disk.zero? && central_disk.zero? && disk_entries == entries && entries < 0xffff && central_size < 0xffffffff && central_offset < 0xffffffff
    raise ScanFailure, "ZIP member count exceeded: #{label}" if entries > MAX_ZIP_MEMBERS
    raise ScanFailure, "malformed ZIP end record: #{label}" unless eocd_offset + 22 + comment_size == data.bytesize
    raise ScanFailure, "malformed ZIP central directory: #{label}" unless central_offset + central_size == eocd_offset

    offset = central_offset
    names = {}
    total_uncompressed = 0
    total_compressed = 0
    members = []
    entries.times do
      raise ScanFailure, "malformed ZIP central entry: #{label}" unless data.byteslice(offset, 4) == "PK\x01\x02".b
      fields = data.byteslice(offset, 46)&.unpack("VvvvvvvVVVvvvvvVV")
      raise ScanFailure, "malformed ZIP central entry: #{label}" unless fields
      _, made_by, needed, flags, method, _time, _date, crc, compressed, uncompressed, name_size, extra_size, comment_length, disk_start, _internal, external, local_offset = fields
      entry_end = offset + 46 + name_size + extra_size + comment_length
      raise ScanFailure, "truncated ZIP central entry: #{label}" if entry_end > eocd_offset
      name = data.byteslice(offset + 46, name_size)
      extra = data.byteslice(offset + 46 + name_size, extra_size)
      validate_extra(extra, label)
      validate_member_metadata(label, name, made_by, needed, flags, method, compressed, uncompressed, disk_start, external, names)
      total_uncompressed += uncompressed
      total_compressed += compressed
      raise ScanFailure, "ZIP total uncompressed byte limit exceeded: #{label}" if total_uncompressed > MAX_TOTAL_MEMBER_BYTES
      raise ScanFailure, "ZIP total compressed byte limit exceeded: #{label}" if total_compressed > MAX_ZIP_COMPRESSED_BYTES
      members << [name, flags, method, crc, compressed, uncompressed, local_offset]
      offset = entry_end
    end
    raise ScanFailure, "ambiguous ZIP central directory: #{label}" unless offset == eocd_offset
    members.each do |name, flags, method, crc, compressed, uncompressed, local_offset|
      scan_bytes("#{label} member name", name)
      member_data = read_member(data, label, name, flags, method, crc, compressed, uncompressed, local_offset)
      scan_bytes("#{label}:#{safe_name(name)}", member_data)
      raise ScanFailure, "nested archive unsupported: #{label}:#{safe_name(name)}" if ZIP_SIGNATURES.any? { |signature| member_data.start_with?(signature) }
    end
  end

  def find_eocd(data)
    start = [0, data.bytesize - 65_557].max
    offset = data.rindex("PK\x05\x06".b)
    raise ScanFailure, "malformed ZIP: end record missing" unless offset && offset >= start && offset + 22 <= data.bytesize
    offset
  end

  def validate_extra(extra, label)
    offset = 0
    while offset < extra.bytesize
      raise ScanFailure, "malformed ZIP extra metadata: #{label}" if offset + 4 > extra.bytesize
      identifier, size = extra.byteslice(offset, 4).unpack("vv")
      raise ScanFailure, "ZIP64 metadata unsupported: #{label}" if identifier == 0x0001
      offset += 4 + size
      raise ScanFailure, "malformed ZIP extra metadata: #{label}" if offset > extra.bytesize
    end
  end

  def validate_member_metadata(label, name, made_by, needed, flags, method, compressed, uncompressed, disk_start, external, names)
    raise ScanFailure, "unsupported ZIP version: #{label}" if needed > 63
    raise ScanFailure, "encrypted ZIP member: #{label}" unless (flags & (0x1 | 0x40 | 0x2000)).zero?
    raise ScanFailure, "unsupported ZIP compression method: #{label}" unless [0, 8].include?(method)
    raise ScanFailure, "multi-disk ZIP member: #{label}" unless disk_start.zero?
    raise ScanFailure, "ZIP member exceeds byte limit: #{label}" if uncompressed > MAX_MEMBER_BYTES
    ratio = compressed.zero? ? (uncompressed.zero? ? 1.0 : Float::INFINITY) : uncompressed.to_f / compressed
    raise ScanFailure, "ZIP compression ratio exceeded: #{label}" if ratio > MAX_COMPRESSION_RATIO
    normalized = safe_name(name).tr("\\", "/")
    components = normalized.split("/", -1)
    raise ScanFailure, "unsafe ZIP member path: #{label}" if normalized.start_with?("/") || components.include?("..") || normalized.include?("\0")
    raise ScanFailure, "duplicate ZIP member name: #{label}" if names.key?(normalized)
    names[normalized] = true
    unix_mode = (external >> 16) & 0xf000
    raise ScanFailure, "symlink ZIP member: #{label}" if (made_by >> 8) == 3 && unix_mode == 0xa000
    raise ScanFailure, "nested archive unsupported: #{label}" if normalized.downcase.end_with?(".zip")
  end

  def safe_name(name)
    text = name.dup.force_encoding(Encoding::UTF_8)
    raise ScanFailure, "invalid ZIP member encoding" unless text.valid_encoding?
    text
  end

  def read_member(data, label, central_name, central_flags, central_method, central_crc, compressed_size, uncompressed_size, local_offset)
    raise ScanFailure, "malformed ZIP local entry: #{label}" unless data.byteslice(local_offset, 4) == "PK\x03\x04".b
    fields = data.byteslice(local_offset, 30)&.unpack("VvvvvvVVVvv")
    raise ScanFailure, "malformed ZIP local entry: #{label}" unless fields
    _, _needed, flags, method, _time, _date, _crc, _compressed, _uncompressed, name_size, extra_size = fields
    name = data.byteslice(local_offset + 30, name_size)
    extra = data.byteslice(local_offset + 30 + name_size, extra_size)
    validate_extra(extra, label)
    raise ScanFailure, "ambiguous ZIP local metadata: #{label}" unless name == central_name && flags == central_flags && method == central_method
    payload_offset = local_offset + 30 + name_size + extra_size
    compressed = data.byteslice(payload_offset, compressed_size)
    raise ScanFailure, "truncated ZIP member: #{label}" unless compressed&.bytesize == compressed_size
    output = case method
             when 0 then compressed
             when 8 then inflate_bounded(compressed, uncompressed_size, label)
             end
    raise ScanFailure, "ZIP member size mismatch: #{label}" unless output.bytesize == uncompressed_size
    raise ScanFailure, "ZIP member checksum mismatch: #{label}" unless Zlib.crc32(output) == central_crc
    output
  rescue Zlib::Error => error
    raise ScanFailure, "malformed ZIP compressed data: #{label} (#{error.class})"
  end

  def inflate_bounded(compressed, expected_size, label)
    inflater = Zlib::Inflate.new(-Zlib::MAX_WBITS)
    output = +"".b
    compressed.bytes.each_slice(256) do |slice|
      output << inflater.inflate(slice.pack("C*"))
      raise ScanFailure, "ZIP member expanded beyond limit: #{label}" if output.bytesize > expected_size || output.bytesize > MAX_MEMBER_BYTES
    end
    output << inflater.finish
    raise ScanFailure, "ZIP member expanded beyond limit: #{label}" if output.bytesize > expected_size || output.bytesize > MAX_MEMBER_BYTES
    output
  ensure
    inflater&.close
  end
end

sentinels = []
if ARGV.first == "--sentinels"
  ARGV.shift
  sentinel_path = ARGV.shift or abort "error: --sentinels requires a file"
  begin
    sentinels = File.readlines(sentinel_path, chomp: true).reject { |line| line.empty? || line.start_with?("#") }
  rescue SystemCallError => error
    abort "error: sentinel file unavailable (#{error.class})"
  end
end

begin
  ArtifactScanner.new(sentinels).scan_roots(ARGV)
  puts "prohibited-content scan passed"
rescue ScanFailure, SystemCallError => error
  warn "error: #{error.message}"
  exit 1
end
