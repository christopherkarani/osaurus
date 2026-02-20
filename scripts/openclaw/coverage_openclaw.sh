#!/usr/bin/env bash
set -euo pipefail

THRESHOLD_PERCENT="${1:-${OPENCLAW_COVERAGE_THRESHOLD:-69}}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/Packages/OsaurusCore"
OUT_DIR="${2:-$ROOT_DIR/.claude/plans/artifacts/openclaw-production/coverage}"

TS_SAFE="$(date -u +'%Y%m%dT%H%M%SZ')-$(uuidgen | cut -d- -f1)"
TS_UTC="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
RUN_DIR="$OUT_DIR/coverage-$TS_SAFE"
mkdir -p "$RUN_DIR"

SWIFT_TEST_LOG="$RUN_DIR/swift-test-openclaw-coverage.log"
LLVM_EXPORT_TMP_JSON="$RUN_DIR/llvm-cov-export.tmp.json"
LLVM_EXPORT_ERR="$RUN_DIR/llvm-cov-export.err.log"
SCOPE_JSON="$RUN_DIR/openclaw-critical-scope.json"
COVERAGE_JSON="$RUN_DIR/openclaw-critical-coverage.json"
PER_FILE_TSV="$RUN_DIR/openclaw-critical-per-file.tsv"
SUMMARY_JSON="$RUN_DIR/summary.json"

write_failure_summary() {
  local reason="$1"
  local detail="${2:-}"

  jq -n \
    --arg ts "$TS_UTC" \
    --arg status "failed" \
    --arg reason "$reason" \
    --arg detail "$detail" \
    --arg threshold "$THRESHOLD_PERCENT" \
    --arg runDir "$RUN_DIR" \
    --arg swiftTestLog "$SWIFT_TEST_LOG" \
    --arg llvmExportErr "$LLVM_EXPORT_ERR" \
    --arg coverageJson "$COVERAGE_JSON" \
    '{
      generatedAtUtc: $ts,
      status: $status,
      reason: $reason,
      detail: (if ($detail | length) == 0 then null else $detail end),
      thresholdPercent: ($threshold | tonumber),
      artifacts: {
        runDir: $runDir,
        swiftTestLog: $swiftTestLog,
        llvmExportErr: $llvmExportErr,
        coverage: $coverageJson
      }
    }' > "$SUMMARY_JSON"

  echo "status=failed"
  echo "threshold_percent=$THRESHOLD_PERCENT"
  echo "line_coverage_percent=0.00"
  echo "summary_json=$SUMMARY_JSON"
  echo "per_file_tsv=$PER_FILE_TSV"
}

if ! (
  cd "$PACKAGE_DIR"
  mkdir -p .build/module-cache .build/xdg-cache
  export SWIFTPM_MODULECACHE_OVERRIDE="$PACKAGE_DIR/.build/module-cache"
  export CLANG_MODULE_CACHE_PATH="$PACKAGE_DIR/.build/module-cache"
  export XDG_CACHE_HOME="$PACKAGE_DIR/.build/xdg-cache"
  swift test --enable-code-coverage --filter OpenClaw > "$SWIFT_TEST_LOG" 2>&1
); then
  write_failure_summary \
    "swift test --enable-code-coverage --filter OpenClaw failed" \
    "See swiftTestLog artifact for compile/test diagnostics."
  exit 1
fi

PROFDATA_PATH="$(find "$PACKAGE_DIR/.build" -type f -path '*/debug/codecov/default.profdata' -print | head -n 1 || true)"
TEST_BINARY_PATH="$(find "$PACKAGE_DIR/.build" -type f -path '*/debug/OsaurusCorePackageTests.xctest/Contents/MacOS/OsaurusCorePackageTests' -print | head -n 1 || true)"

if [[ -z "$PROFDATA_PATH" || ! -f "$PROFDATA_PATH" ]]; then
  write_failure_summary "Coverage profile not found" "Expected .build/*/debug/codecov/default.profdata."
  exit 1
fi

if [[ -z "$TEST_BINARY_PATH" || ! -f "$TEST_BINARY_PATH" ]]; then
  write_failure_summary "Coverage test binary not found" "Expected OsaurusCorePackageTests XCTest binary in .build."
  exit 1
fi

if ! xcrun llvm-cov export -format=text -instr-profile "$PROFDATA_PATH" "$TEST_BINARY_PATH" > "$LLVM_EXPORT_TMP_JSON" 2> "$LLVM_EXPORT_ERR"; then
  write_failure_summary "llvm-cov export failed" "See llvmExport stderr artifact for details."
  exit 1
fi

jq -n \
  --arg f1 "$PACKAGE_DIR/Services/OpenClawGatewayConnection.swift" \
  --arg f2 "$PACKAGE_DIR/Services/OpenClawModelService.swift" \
  --arg f3 "$PACKAGE_DIR/Services/OpenClawEventProcessor.swift" \
  --arg f4 "$PACKAGE_DIR/Services/OpenClawNotificationService.swift" \
  --arg f5 "$PACKAGE_DIR/Services/OpenClawSessionManager.swift" \
  --arg f6 "$PACKAGE_DIR/Services/OpenClawChatHistoryLoader.swift" \
  --arg f7 "$PACKAGE_DIR/Models/OpenClawChannelStatus.swift" \
  --arg f8 "$PACKAGE_DIR/Models/OpenClawPresenceModels.swift" \
  '[$f1, $f2, $f3, $f4, $f5, $f6, $f7, $f8]' > "$SCOPE_JSON"

jq --slurpfile scope "$SCOPE_JSON" '
  .data[0].files
  | map(select((.filename as $f | ($scope[0] | index($f)) != null)))
  | {
      files: length,
      linesCovered: (map(.summary.lines.covered // 0) | add // 0),
      linesTotal: (map(.summary.lines.count // 0) | add // 0),
      lineCoveragePercent: (
        (map(.summary.lines.covered // 0) | add // 0) as $covered
        | (map(.summary.lines.count // 0) | add // 0) as $total
        | if $total > 0 then (($covered / $total) * 100) else 0 end
      ),
      perFile: (
        map({
          file: .filename,
          linesCovered: (.summary.lines.covered // 0),
          linesTotal: (.summary.lines.count // 0),
          lineCoveragePercent: (
            (.summary.lines.covered // 0) as $covered
            | (.summary.lines.count // 0) as $total
            | if $total > 0 then (($covered / $total) * 100) else 0 end
          )
        })
        | sort_by(.file)
      )
    }
' "$LLVM_EXPORT_TMP_JSON" > "$COVERAGE_JSON"

SCOPE_FILE_COUNT="$(jq -r '.files // 0' "$COVERAGE_JSON")"
if [[ "$SCOPE_FILE_COUNT" -eq 0 ]]; then
  write_failure_summary "No files matched OpenClaw-critical coverage scope" "Coverage scope list did not match llvm-cov export filenames."
  exit 1
fi

jq -r '
  .perFile[]
  | [
      (.file | sub("^.*/Packages/OsaurusCore/"; "")),
      (.linesCovered | tostring),
      (.linesTotal | tostring),
      (.lineCoveragePercent | tostring)
    ]
  | @tsv
' "$COVERAGE_JSON" > "$PER_FILE_TSV"

rm -f "$LLVM_EXPORT_TMP_JSON"

LINE_COVERAGE_PERCENT="$(jq -r '.lineCoveragePercent' "$COVERAGE_JSON")"
STATUS="failed"
REASON="OpenClaw-critical line coverage is below threshold."
if awk "BEGIN {exit !($LINE_COVERAGE_PERCENT >= $THRESHOLD_PERCENT)}"; then
  STATUS="passed"
  REASON="OpenClaw-critical line coverage meets threshold."
fi

FORMATTED_COVERAGE="$(printf '%.2f' "$LINE_COVERAGE_PERCENT")"

jq -n \
  --arg ts "$TS_UTC" \
  --arg status "$STATUS" \
  --arg reason "$REASON" \
  --arg threshold "$THRESHOLD_PERCENT" \
  --arg profdata "$PROFDATA_PATH" \
  --arg testBinary "$TEST_BINARY_PATH" \
  --arg runDir "$RUN_DIR" \
  --arg swiftTestLog "$SWIFT_TEST_LOG" \
  --arg llvmExportErr "$LLVM_EXPORT_ERR" \
  --arg coverageJson "$COVERAGE_JSON" \
  --arg scopeJson "$SCOPE_JSON" \
  --arg perFileTsv "$PER_FILE_TSV" \
  --slurpfile scope "$SCOPE_JSON" \
  --slurpfile metrics "$COVERAGE_JSON" \
  '{
    generatedAtUtc: $ts,
    status: $status,
    reason: $reason,
    thresholdPercent: ($threshold | tonumber),
    scope: $scope[0],
    metrics: $metrics[0],
    artifacts: {
      runDir: $runDir,
      swiftTestLog: $swiftTestLog,
      llvmExportErr: $llvmExportErr,
      coverage: $coverageJson,
      scope: $scopeJson,
      perFileCoverage: $perFileTsv
    },
    coverageTooling: {
      profdataPath: $profdata,
      testBinaryPath: $testBinary
    }
  }' > "$SUMMARY_JSON"

echo "status=$STATUS"
echo "threshold_percent=$THRESHOLD_PERCENT"
echo "line_coverage_percent=$FORMATTED_COVERAGE"
echo "summary_json=$SUMMARY_JSON"
echo "per_file_tsv=$PER_FILE_TSV"
