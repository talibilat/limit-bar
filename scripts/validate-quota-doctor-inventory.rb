#!/usr/bin/env ruby
# frozen_string_literal: true

require "date"
require "json"

root = File.expand_path("..", __dir__)
inventory_path = ARGV[0] || File.join(root, "config/quota-doctor-adapters.json")
summary_path = ARGV[1]
markdown_path = ARGV[2]
abort "usage: #{$PROGRAM_NAME} INVENTORY SUMMARY MARKDOWN" unless summary_path && markdown_path

inventory = JSON.parse(File.read(inventory_path))
abort "unsupported inventory format" unless inventory["formatVersion"] == 1
required = %w[id providerProduct category stability releaseSupported supportedVersions capturedFields omittedFields authenticationAccess userVisibleOSInteraction confidence lastVerified configuredReadBoundary limitations fixtureSuites failureSuites]
allowed_stability = %w[stable experimental verification-only unavailable]
declarations = inventory.fetch("declarations")
abort "adapter declarations must not be empty" unless declarations.is_a?(Array) && !declarations.empty?
ids = declarations.map { |declaration| declaration["id"] }
abort "adapter IDs must be unique" unless ids.uniq.length == ids.length
identity_values = [
  inventory.dig("application", "marketingVersion"),
  inventory.dig("application", "buildVersion"),
  *inventory.fetch("methods").values
]
abort "version identities must be bounded safe tokens" unless identity_values.all? { |value| value.is_a?(String) && value.match?(/\A[A-Za-z0-9._-]{1,128}\z/) }

declarations.each do |declaration|
  missing = required.reject { |field| declaration.key?(field) }
  abort "#{declaration.fetch("id", "unknown")} missing fields: #{missing.join(", ")}" unless missing.empty?
  abort "invalid category" unless %w[subscription api].include?(declaration["category"])
  abort "invalid stability" unless allowed_stability.include?(declaration["stability"])
  abort "releaseSupported must be boolean" unless [true, false].include?(declaration["releaseSupported"])
  %w[supportedVersions capturedFields omittedFields limitations fixtureSuites failureSuites].each do |field|
    value = declaration[field]
    abort "#{declaration["id"]} #{field} must be a nonempty string array" unless value.is_a?(Array) && !value.empty? && value.all? { |entry| entry.is_a?(String) && !entry.empty? }
  end
  %w[authenticationAccess userVisibleOSInteraction confidence configuredReadBoundary].each do |field|
    abort "#{declaration["id"]} #{field} must be nonempty" unless declaration[field].is_a?(String) && !declaration[field].empty?
  end
  Date.iso8601(declaration["lastVerified"])
  (declaration["fixtureSuites"] + declaration["failureSuites"]).each do |reference|
    abort "missing suite reference: #{reference}" unless File.file?(File.join(root, reference))
  end
end

project = File.read(File.join(root, "LimitBar.xcodeproj/project.pbxproj"))
abort "marketing version drift" unless project.include?("MARKETING_VERSION = #{inventory.dig("application", "marketingVersion")};")
abort "build version drift" unless project.include?("CURRENT_PROJECT_VERSION = #{inventory.dig("application", "buildVersion")};")
expected_code_values = {
  inventory.dig("methods", "forecast") => "LimitBarCore/Sources/LimitBarCore/QuotaInsights.swift",
  inventory.dig("methods", "anomaly") => "LimitBarCore/Sources/LimitBarCore/QuotaAnomaly.swift",
  inventory.dig("methods", "codexExplanation") => "LimitBarCore/Sources/LimitBarCore/CodexQuotaExplanation.swift",
  inventory.dig("methods", "claudeExplanation") => "LimitBarCore/Sources/LimitBarCore/ClaudeQuotaExplanation.swift",
  inventory.dig("methods", "workloadComparability") => "LimitBarCore/Sources/LimitBarCore/PlannedWorkloadAssessment.swift",
  inventory.dig("methods", "workloadRange") => "LimitBarCore/Sources/LimitBarCore/PlannedWorkloadAssessment.swift"
}
expected_code_values.each do |value, relative_path|
  abort "missing declared code identity" unless value.is_a?(String) && File.read(File.join(root, relative_path)).include?(value)
end
abort "quota schema drift" unless File.read(File.join(root, "LimitBarCore/Sources/LimitBarCore/QuotaInsights.swift")).include?("schemaVersion = #{inventory.dig("schemas", "quotaObservations")}")
abort "Claude schema drift" unless File.read(File.join(root, "LimitBarCore/Sources/LimitBarCore/ClaudeExplanationStore.swift")).include?("schemaVersion = #{inventory.dig("schemas", "claudeExplanations")}")

stable_subscription = declarations.count { |item| item["category"] == "subscription" && item["stability"] == "stable" && item["releaseSupported"] }
stable_api = declarations.count { |item| item["category"] == "api" && item["stability"] == "stable" && item["releaseSupported"] }

File.write(summary_path, <<~SUMMARY)
  APP_MARKETING_VERSION=#{inventory.dig("application", "marketingVersion")}
  APP_BUILD_VERSION=#{inventory.dig("application", "buildVersion")}
  QUOTA_SCHEMA_VERSION=#{inventory.dig("schemas", "quotaObservations")}
  CLAUDE_SCHEMA_VERSION=#{inventory.dig("schemas", "claudeExplanations")}
  FORECAST_METHOD=#{inventory.dig("methods", "forecast")}
  ANOMALY_METHOD=#{inventory.dig("methods", "anomaly")}
  CODEX_EXPLANATION_METHOD=#{inventory.dig("methods", "codexExplanation")}
  CLAUDE_EXPLANATION_METHOD=#{inventory.dig("methods", "claudeExplanation")}
  WORKLOAD_COMPARABILITY_METHOD=#{inventory.dig("methods", "workloadComparability")}
  WORKLOAD_RANGE_METHOD=#{inventory.dig("methods", "workloadRange")}
  STABLE_SUBSCRIPTION_COUNT=#{stable_subscription}
  STABLE_API_COUNT=#{stable_api}
SUMMARY

rows = declarations.map do |item|
  versions = item["supportedVersions"].join("; ").gsub("|", "\\|")
  "| `#{item["id"]}` | #{item["providerProduct"]} | #{item["stability"]} | #{versions} | #{item["confidence"]} | #{item["lastVerified"]} |"
end
File.write(markdown_path, ([
  "| Adapter declaration | Provider product | Stability | Version boundary | Confidence | Last verified |",
  "| --- | --- | --- | --- | --- | --- |"
] + rows).join("\n") + "\n")

puts "quota-doctor adapter inventory passed: stable subscriptions=#{stable_subscription}, stable APIs=#{stable_api}"
