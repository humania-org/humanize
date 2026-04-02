#!/usr/bin/env bash
#
# Shared helpers for scenario matrix runtime state.
#

[[ -n "${_SCENARIO_MATRIX_LOADED:-}" ]] && return 0 2>/dev/null || true
_SCENARIO_MATRIX_LOADED=1

readonly SCENARIO_MATRIX_SCHEMA_VERSION=2

scenario_matrix_trim() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

scenario_matrix_normalize_header() {
    printf '%s' "$1" \
        | tr '[:upper:]' '[:lower:]' \
        | tr -d '`' \
        | sed 's/[[:space:]]*(.*$//; s/[[:space:]]\+/ /g; s/^[[:space:]]*//; s/[[:space:]]*$//'
}

scenario_matrix_row_to_cells() {
    local row
    row=$(scenario_matrix_trim "$1")
    [[ "$row" == \|* ]] && row="${row#|}"
    [[ "$row" == *\| ]] && row="${row%|}"
    printf '%s' "$row" | jq -rR 'split("|") | map(gsub("^\\s+|\\s+$"; "")) | .[]'
}

scenario_matrix_read_lines_into_array() {
    local target_var="$1"
    local input_text="$2"
    local line quoted_line

    eval "$target_var=()"
    if [[ -z "$input_text" ]]; then
        return 0
    fi

    while IFS= read -r line; do
        printf -v quoted_line '%q' "$line"
        eval "$target_var+=( $quoted_line )"
    done <<< "$input_text"
}

scenario_matrix_csv_to_json_array() {
    local raw
    raw=$(scenario_matrix_trim "$1")
    if [[ -z "$raw" || "$raw" == "-" ]]; then
        printf '[]\n'
        return 0
    fi

    printf '%s' "$raw" | jq -R 'split(",") | map(gsub("^\\s+|\\s+$"; "") | select(length > 0 and . != "-"))'
}

scenario_matrix_json_array_from_lines() {
    if [[ $# -eq 0 ]]; then
        printf '[]\n'
        return 0
    fi

    printf '%s\n' "$@" | jq -R . | jq -s .
}

scenario_matrix_lines_to_json_string() {
    if [[ $# -eq 0 ]]; then
        printf '""\n'
        return 0
    fi

    printf '%s\n' "$@" | jq -Rs 'sub("\\n$"; "")'
}

scenario_matrix_parse_coverage_ledger_paragraph_json() {
    local paragraph="$1"
    local normalized

    normalized=$(printf '%s' "$paragraph" | jq -Rs 'gsub("\\r"; "") | gsub("\\n+"; " ") | gsub("[[:space:]]+"; " ") | gsub("^\\s+|\\s+$"; "")')

    jq -cn --argjson paragraph "$normalized" '
        def trim_text:
            gsub("^\\s+|\\s+$"; "");
        def clean_surface:
            trim_text
            | sub("^[*-][[:space:]]*"; "")
            | sub("^[0-9]+\\.[[:space:]]*"; "")
            | sub("^[Ss]urface:[[:space:]]*"; "");
        def clean_notes:
            trim_text
            | sub("^[Nn]otes?:[[:space:]]*"; "")
            | sub("^[;:.,-]+[[:space:]]*"; "");

        ($paragraph | trim_text) as $raw
        | if $raw == "" then
            empty
          else
            (
                (try ($raw | capture("^surface:[[:space:]]*(?<surface>.+?)[[:space:]]*(?:[;|,])[[:space:]]*status:[[:space:]]*(?<status>covered|partial|unclear)\\b(?<notes>.*)$"; "i")) catch null)
                // (try ($raw | capture("^(?<surface>.+?)[[:space:]]*\\|[[:space:]]*(?<status>covered|partial|unclear)[[:space:]]*\\|(?<notes>.*)$"; "i")) catch null)
                // (try ($raw | capture("^(?<surface>.+?)[[:space:]]*:[[:space:]]*(?<status>covered|partial|unclear)\\b(?<notes>.*)$"; "i")) catch null)
                // (try ($raw | capture("^(?<surface>.+?)[[:space:]]+is[[:space:]]+(?<status>covered|partial|unclear)\\b(?<notes>.*)$"; "i")) catch null)
                // (try ($raw | capture("^(?<surface>.+?)[[:space:]]*-[[:space:]]*(?<status>covered|partial|unclear)\\b(?<notes>.*)$"; "i")) catch null)
            ) as $match
            | if $match == null then
                empty
              else
                {
                    surface: (($match.surface // "") | clean_surface),
                    status: (($match.status // "unclear") | ascii_downcase),
                    notes: (($match.notes // "") | clean_notes)
                }
                | select(.surface != "")
              end
          end
    '
}

scenario_matrix_emit_breakdown_result() {
    local result_status="$1"
    local tasks_json="$2"
    local warnings_json="$3"

    jq -cn \
        --arg result_status "$result_status" \
        --argjson tasks "$tasks_json" \
        --argjson warnings "$warnings_json" \
        '{
            status: $result_status,
            tasks: $tasks,
            warnings: $warnings
        }'
}

scenario_matrix_extract_task_breakdown_section() {
    local plan_path="$1"

    awk '
        /^##[[:space:]]*Task Breakdown([[:space:]]*$|[[:space:][:punct:]].*)/ {
            in_section = 1
            next
        }
        /^##[[:space:]]+/ {
            if (in_section) {
                exit
            }
        }
        in_section {
            print
        }
    ' "$plan_path"
}

scenario_matrix_parse_task_breakdown_json() {
    local plan_path="$1"
    local section

    section=$(scenario_matrix_extract_task_breakdown_section "$plan_path")
    if [[ -z "$section" ]]; then
        scenario_matrix_emit_breakdown_result "missing" '[]' '[]'
        return 0
    fi

    local -a table_lines=()
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*\| ]] || continue
        table_lines+=("$line")
    done <<< "$section"

    if [[ ${#table_lines[@]} -lt 2 ]]; then
        scenario_matrix_emit_breakdown_result \
            "malformed" \
            '[]' \
            "$(scenario_matrix_json_array_from_lines "Task Breakdown section is present but does not contain a valid markdown table.")"
        return 0
    fi

    local header_line="${table_lines[0]}"
    local separator_line="${table_lines[1]}"

    if ! printf '%s\n' "$separator_line" | grep -qE '^[[:space:]|:-]+$'; then
        scenario_matrix_emit_breakdown_result \
            "malformed" \
            '[]' \
            "$(scenario_matrix_json_array_from_lines "Task Breakdown table separator row is malformed.")"
        return 0
    fi

    local -a header_cells=()
    scenario_matrix_read_lines_into_array header_cells "$(scenario_matrix_row_to_cells "$header_line")"

    local idx_task_id=-1
    local idx_description=-1
    local idx_target_ac=-1
    local idx_tag=-1
    local idx_depends_on=-1

    local i normalized_header
    for i in "${!header_cells[@]}"; do
        normalized_header=$(scenario_matrix_normalize_header "${header_cells[$i]}")
        case "$normalized_header" in
            "task id")
                idx_task_id=$i
                ;;
            "description")
                idx_description=$i
                ;;
            "target ac")
                idx_target_ac=$i
                ;;
            tag*)
                idx_tag=$i
                ;;
            "depends on")
                idx_depends_on=$i
                ;;
        esac
    done

    if [[ $idx_task_id -lt 0 || $idx_description -lt 0 || $idx_target_ac -lt 0 || $idx_tag -lt 0 || $idx_depends_on -lt 0 ]]; then
        scenario_matrix_emit_breakdown_result \
            "malformed" \
            '[]' \
            "$(scenario_matrix_json_array_from_lines "Task Breakdown header must include Task ID, Description, Target AC, Tag, and Depends On columns.")"
        return 0
    fi

    local tasks_json='[]'
    local malformed_message=""
    local row_number task_id description target_ac_raw tag_raw depends_on_raw tag_lower
    local target_ac_json depends_on_json state task_json lane seeded_task_count
    seeded_task_count=0

    for ((i = 2; i < ${#table_lines[@]}; i++)); do
        local -a row_cells=()
        scenario_matrix_read_lines_into_array row_cells "$(scenario_matrix_row_to_cells "${table_lines[$i]}")"
        row_number=$i

        task_id=$(scenario_matrix_trim "${row_cells[$idx_task_id]:-}")
        description=$(scenario_matrix_trim "${row_cells[$idx_description]:-}")
        target_ac_raw=$(scenario_matrix_trim "${row_cells[$idx_target_ac]:-}")
        tag_raw=$(scenario_matrix_trim "${row_cells[$idx_tag]:-}")
        depends_on_raw=$(scenario_matrix_trim "${row_cells[$idx_depends_on]:-}")

        if [[ -z "$task_id" && -z "$description" && -z "$target_ac_raw" && -z "$tag_raw" && -z "$depends_on_raw" ]]; then
            continue
        fi

        if [[ -z "$task_id" || ! "$task_id" =~ ^[a-zA-Z0-9._-]+$ ]]; then
            malformed_message="Task Breakdown row $row_number has an invalid Task ID."
            break
        fi

        if [[ -z "$description" ]]; then
            malformed_message="Task Breakdown row $row_number is missing a Description."
            break
        fi

        target_ac_json=$(scenario_matrix_csv_to_json_array "$target_ac_raw")
        if [[ "$(printf '%s' "$target_ac_json" | jq 'length')" -eq 0 ]]; then
            malformed_message="Task Breakdown row $row_number is missing Target AC entries."
            break
        fi

        tag_lower=$(printf '%s' "$tag_raw" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
        if [[ "$tag_lower" != "coding" && "$tag_lower" != "analyze" ]]; then
            malformed_message="Task Breakdown row $row_number has an invalid Tag value: $tag_raw"
            break
        fi

        depends_on_json=$(scenario_matrix_csv_to_json_array "$depends_on_raw")
        state="pending"
        if [[ "$(printf '%s' "$depends_on_json" | jq 'length')" -eq 0 ]]; then
            state="ready"
        fi
        lane="supporting"
        if [[ "$seeded_task_count" -eq 0 ]]; then
            lane="mainline"
        fi

        task_json=$(jq -cn \
            --arg id "$task_id" \
            --arg title "$description" \
            --arg lane "$lane" \
            --arg routing "$tag_lower" \
            --arg state "$state" \
            --argjson target_ac "$target_ac_json" \
            --argjson depends_on "$depends_on_json" '
            {
                id: $id,
                title: $title,
                lane: $lane,
                routing: $routing,
                source: "plan",
                kind: "feature",
                severity: null,
                confidence: null,
                finding_status: null,
                file_ref: null,
                review_phase: null,
                owner: null,
                scope: {
                    summary: "",
                    paths: [],
                    constraints: []
                },
                cluster_id: null,
                repair_wave: null,
                risk_bucket: "planned",
                admission: {
                    status: "active",
                    reason: "seeded_from_plan"
                },
                authority: {
                    write_mode: "manager_only",
                    authoritative_source: "manager"
                },
                target_ac: $target_ac,
                depends_on: $depends_on,
                state: $state,
                assumptions: [],
                strategy: {
                    current: "",
                    attempt_count: 0,
                    repeated_failure_count: 0,
                    method_switch_required: false
                },
                health: {
                    stuck_score: 0,
                    last_progress_round: 0
                },
                metadata: {
                    seed_source: "task_breakdown"
                }
            }')

        tasks_json=$(jq -cn --argjson tasks "$tasks_json" --argjson task "$task_json" '$tasks + [$task]')
        seeded_task_count=$((seeded_task_count + 1))
    done

    if [[ -n "$malformed_message" ]]; then
        scenario_matrix_emit_breakdown_result \
            "malformed" \
            '[]' \
            "$(scenario_matrix_json_array_from_lines "$malformed_message")"
        return 0
    fi

    scenario_matrix_emit_breakdown_result "parsed" "$tasks_json" '[]'
}

scenario_matrix_initialize_file() {
    local matrix_file="$1"
    local logical_plan_file="$2"
    local backup_plan_file="$3"
    local mode="$4"
    local current_round="${5:-0}"
    local status_override="${6:-}"
    local resolved_backup_plan_file=""

    if [[ -n "$backup_plan_file" ]]; then
        if [[ "$backup_plan_file" == /* ]]; then
            resolved_backup_plan_file="$backup_plan_file"
        elif [[ -f "$backup_plan_file" ]]; then
            resolved_backup_plan_file="$backup_plan_file"
        else
            local matrix_repo_root=""
            matrix_repo_root=$(cd "$(dirname "$matrix_file")/../../.." 2>/dev/null && pwd) || matrix_repo_root=""
            if [[ -n "$matrix_repo_root" && -f "$matrix_repo_root/$backup_plan_file" ]]; then
                resolved_backup_plan_file="$matrix_repo_root/$backup_plan_file"
            fi
        fi
    fi

    local breakdown_json
    case "$status_override" in
        "not_applicable")
            breakdown_json='{"status":"not_applicable","tasks":[],"warnings":[]}'
            ;;
        *)
            if [[ -n "$resolved_backup_plan_file" && -f "$resolved_backup_plan_file" ]]; then
                breakdown_json=$(scenario_matrix_parse_task_breakdown_json "$resolved_backup_plan_file")
            else
                breakdown_json='{"status":"missing","tasks":[],"warnings":[]}'
            fi
            ;;
    esac

    local temp_file="${matrix_file}.tmp.$$"
    jq -cn \
        --arg logical_plan_file "$logical_plan_file" \
        --arg backup_plan_file "$backup_plan_file" \
        --arg mode "$mode" \
        --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson current_round "$current_round" \
        --argjson breakdown "$breakdown_json" \
        '{
            schema_version: '"$SCENARIO_MATRIX_SCHEMA_VERSION"',
            created_at: $created_at,
            plan: {
                file: $logical_plan_file,
                backup_file: $backup_plan_file,
                task_breakdown_status: ($breakdown.status // "missing"),
                warnings: ($breakdown.warnings // [])
            },
            runtime: {
                mode: $mode,
                current_round: $current_round,
                projection_mode: "compatibility",
                checkpoint: {
                    sequence: 0,
                    current_id: "",
                    frontier_signature: "",
                    frontier_changed: false,
                    primary_task_id: null,
                    supporting_task_ids: [],
                    frontier_reason: "uninitialized",
                    updated_at: null
                },
                convergence: {
                    status: "continue",
                    next_action: "hold_checkpoint",
                    guidance: "Reconcile the manager frontier before deriving execution guidance.",
                    residual_risk_score: 0,
                    must_fix_open_count: 0,
                    high_risk_open_count: 0,
                    active_task_count: 0,
                    watchlist_count: 0,
                    recent_high_value_novelty_count: 0,
                    updated_at: null
                }
            },
            metadata: {
                seed_task_count: (($breakdown.tasks // []) | length),
                seed_source: (
                    if ($breakdown.status // "missing") == "parsed" then
                        "task_breakdown"
                    elif ($breakdown.status // "missing") == "not_applicable" then
                        "not_applicable"
                    else
                        "fallback"
                    end
                )
            },
            manager: {
                role: "top_level_session",
                authority_mode: "manager_reconcile",
                authoritative_writer: "manager",
                current_primary_task_id: (
                    first(
                        ($breakdown.tasks // [])[].id
                    ) // null
                ),
                last_reconciled_at: $created_at
            },
            feedback: {
                execution: [],
                review: []
            },
            raw_findings: [],
            finding_groups: [],
            tasks: ($breakdown.tasks // []),
            events: [],
            oversight: {
                status: "idle",
                last_action: "none",
                updated_at: null,
                intervention: null,
                history: []
            }
        }' > "$temp_file"

    mv "$temp_file" "$matrix_file"
}

scenario_matrix_validate_file() {
    local matrix_file="$1"

    jq -e '
        def valid_string_array:
            type == "array" and all(.[]; type == "string");

        def valid_optional_string:
            . == null or type == "string";

        def valid_optional_number:
            . == null or type == "number";

        def valid_scope:
            type == "object"
            and ((.summary // "") | type) == "string"
            and ((.paths // []) | valid_string_array)
            and ((.constraints // []) | valid_string_array);

        def valid_checkpoint:
            type == "object"
            and ((.sequence // 0) | type) == "number"
            and ((.current_id // "") | type) == "string"
            and ((.frontier_signature // "") | type) == "string"
            and ((.frontier_changed // false) | type) == "boolean"
            and ((.primary_task_id // null) | valid_optional_string)
            and ((.supporting_task_ids // []) | valid_string_array)
            and ((.frontier_reason // "") | type) == "string"
            and ((.updated_at // null) | valid_optional_string);

        def valid_convergence:
            type == "object"
            and ((.status // "continue") | type) == "string"
            and ((.next_action // "hold_checkpoint") | type) == "string"
            and ((.guidance // "") | type) == "string"
            and ((.residual_risk_score // 0) | type) == "number"
            and ((.must_fix_open_count // 0) | type) == "number"
            and ((.high_risk_open_count // 0) | type) == "number"
            and ((.active_task_count // 0) | type) == "number"
            and ((.watchlist_count // 0) | type) == "number"
            and ((.recent_high_value_novelty_count // 0) | type) == "number"
            and ((.updated_at // null) | valid_optional_string);

        def valid_review_surface_entry:
            type == "object"
            and ((.surface // "") | type) == "string"
            and ((.reason // "") | type) == "string"
            and ((.confidence // null) | valid_optional_string);

        def valid_sibling_risk_entry:
            type == "object"
            and ((.summary // "") | type) == "string"
            and ((.derived_from // null) | valid_optional_string)
            and ((.expansion_axis // null) | valid_optional_string)
            and ((.why_likely // null) | valid_optional_string)
            and ((.recommended_check // null) | valid_optional_string)
            and ((.confidence // null) | valid_optional_string);

        def valid_coverage_ledger_entry:
            type == "object"
            and ((.surface // "") | type) == "string"
            and ((.status // "") | type) == "string"
            and ((.notes // "") | type) == "string";

        def valid_review_coverage:
            type == "object"
            and ((.source_phase // null) | valid_optional_string)
            and ((.source_round // 0) | type) == "number"
            and ((.updated_at // null) | valid_optional_string)
            and ((.touched_failure_surfaces // []) | type) == "array"
            and all((.touched_failure_surfaces // [])[]; valid_review_surface_entry)
            and ((.likely_sibling_risks // []) | type) == "array"
            and all((.likely_sibling_risks // [])[]; valid_sibling_risk_entry)
            and ((.coverage_ledger // []) | type) == "array"
            and all((.coverage_ledger // [])[]; valid_coverage_ledger_entry)
            and ((.raw_sections // {}) | type) == "object"
            and (((.raw_sections.touched_failure_surfaces // "") | type) == "string")
            and (((.raw_sections.likely_sibling_risks // "") | type) == "string")
            and (((.raw_sections.coverage_ledger // "") | type) == "string")
            and ((.summary // {}) | type) == "object"
            and (((.summary.surface_count // 0) | type) == "number")
            and (((.summary.sibling_risk_count // 0) | type) == "number")
            and (((.summary.covered_count // 0) | type) == "number")
            and (((.summary.partial_or_unclear_count // 0) | type) == "number");

        def valid_admission:
            type == "object"
            and ((.status // "active") | type) == "string"
            and ((.reason // "") | type) == "string";

        def valid_task_authority:
            type == "object"
            and ((.write_mode // "manager_only") == "manager_only")
            and ((.authoritative_source // "manager") == "manager");

        def valid_v2_task_fields:
            ((.owner // null) | valid_optional_string)
            and ((.owner // "") != "manager")
            and ((.scope // {}) | valid_scope)
            and ((.cluster_id // null) | valid_optional_string)
            and ((.repair_wave // null) | valid_optional_string)
            and ((.risk_bucket // "normal") | type) == "string"
            and ((.admission // {}) | valid_admission)
            and ((.authority // {}) | valid_task_authority);

        def valid_task:
            type == "object"
            and (.id | type) == "string"
            and (.title | type) == "string"
            and (.lane | type) == "string"
            and (.routing | type) == "string"
            and ((.source // "plan") | type) == "string"
            and ((.kind // "feature") | type) == "string"
            and ((.severity // null) | valid_optional_string)
            and ((.confidence // null) | valid_optional_number)
            and ((.finding_status // null) | valid_optional_string)
            and ((.file_ref // null) | valid_optional_string)
            and ((.review_phase // null) | valid_optional_string)
            and (.target_ac | valid_string_array)
            and (.depends_on | valid_string_array)
            and (.state | type) == "string"
            and (.assumptions | valid_string_array)
            and (.strategy | type) == "object"
            and ((.strategy.current // "") | type) == "string"
            and ((.strategy.attempt_count // 0) | type) == "number"
            and ((.strategy.repeated_failure_count // 0) | type) == "number"
            and ((.strategy.method_switch_required // false) | type) == "boolean"
            and (.health | type) == "object"
            and ((.health.stuck_score // 0) | type) == "number"
            and ((.health.last_progress_round // 0) | type) == "number"
            and ((.metadata // {}) | type) == "object";

        def valid_feedback_entry:
            type == "object"
            and ((.source // "") | type) == "string"
            and ((.kind // "") | type) == "string"
            and ((.summary // "") | type) == "string"
            and ((.suggested_by // "") | type) == "string"
            and ((.task_id // null) | valid_optional_string)
            and ((.source_file // null) | valid_optional_string)
            and ((.created_at // null) | valid_optional_string)
            and ((.authoritative // false) == false);

        def valid_raw_finding:
            type == "object"
            and ((.id // "") | type) == "string"
            and ((.title // "") | type) == "string"
            and ((.summary // "") | type) == "string"
            and ((.severity // null) | valid_optional_string)
            and ((.confidence // null) == null or (.confidence | type) == "number")
            and ((.source // "") | type) == "string"
            and ((.kind // "") | type) == "string"
            and ((.review_phase // "") | type) == "string"
            and ((.cluster_id // null) | valid_optional_string)
            and ((.repair_wave_hint // null) | valid_optional_string)
            and ((.admission_status // "") | type) == "string"
            and ((.admission_reason // "") | type) == "string"
            and ((.lane // "") | type) == "string"
            and ((.state // "") | type) == "string"
            and ((.routing // "") | type) == "string"
            and ((.risk_bucket // "") | type) == "string"
            and ((.finding_key // "") | type) == "string"
            and ((.related_task_id // null) | valid_optional_string)
            and ((.link_task_id // null) | valid_optional_string)
            and ((.file_ref // null) | valid_optional_string)
            and ((.target_ac // []) | valid_string_array)
            and ((.depends_on // []) | valid_string_array)
            and ((.surface_key // "") | type) == "string"
            and ((.surface_label // "") | type) == "string"
            and ((.group_key // "") | type) == "string"
            and ((.first_seen_round // 0) | type) == "number"
            and ((.last_seen_round // 0) | type) == "number"
            and ((.occurrence_count // 0) | type) == "number";

        def valid_finding_group:
            type == "object"
            and ((.id // "") | type) == "string"
            and ((.title // "") | type) == "string"
            and ((.summary // "") | type) == "string"
            and ((.surface_key // "") | type) == "string"
            and ((.surface_label // "") | type) == "string"
            and ((.state // "") | type) == "string"
            and ((.admission_status // "") | type) == "string"
            and ((.severity // null) | valid_optional_string)
            and ((.risk_bucket // "") | type) == "string"
            and ((.target_ac // []) | valid_string_array)
            and ((.related_task_ids // []) | valid_string_array)
            and ((.file_refs // []) | valid_string_array)
            and ((.finding_ids // []) | valid_string_array)
            and ((.sample_summaries // []) | valid_string_array)
            and ((.finding_count // 0) | type) == "number"
            and ((.first_seen_round // 0) | type) == "number"
            and ((.last_seen_round // 0) | type) == "number";

        def valid_manager:
            type == "object"
            and ((.role // "") | type) == "string"
            and ((.authority_mode // "") == "manager_reconcile")
            and ((.authoritative_writer // "") == "manager")
            and ((.current_primary_task_id // null) | valid_optional_string)
            and ((.last_reconciled_at // null) | valid_optional_string);

        def active_mainlines:
            [
                .tasks[]
                | select(.lane == "mainline")
                | select(.state != "done" and .state != "deferred")
            ];

        (.schema_version | type) == "number"
        and (.schema_version >= 1 and .schema_version <= '"$SCENARIO_MATRIX_SCHEMA_VERSION"')
        and (.plan | type) == "object"
        and (.plan.task_breakdown_status | type) == "string"
        and ((.plan.warnings // []) | type) == "array"
        and all((.plan.warnings // [])[]; type == "string")
        and (.runtime | type) == "object"
        and (.runtime.mode | type) == "string"
        and ((.runtime.current_round // 0) | type) == "number"
        and ((.runtime.checkpoint // {}) | valid_checkpoint)
        and ((.runtime.convergence // {}) | valid_convergence)
        and (((.runtime.review_coverage // null) == null) or ((.runtime.review_coverage // {}) | valid_review_coverage))
        and (.tasks | type) == "array"
        and all(.tasks[]; valid_task)
        and (.events | type) == "array"
        and all(.events[]; type == "object")
        and (.oversight | type) == "object"
        and ((.oversight.status // "idle") | type) == "string"
        and ((.oversight.last_action // "none") | type) == "string"
        and ((.oversight.intervention == null) or (.oversight.intervention | type) == "object")
        and ((.oversight.history // []) | type) == "array"
        and all((.oversight.history // [])[]; type == "object")
        and (
            if .schema_version >= 2 then
                (.manager | valid_manager)
                and all(.tasks[]; valid_v2_task_fields)
                and (.feedback | type) == "object"
                and ((.feedback.execution // []) | type) == "array"
                and all((.feedback.execution // [])[]; valid_feedback_entry)
                and ((.feedback.review // []) | type) == "array"
                and all((.feedback.review // [])[]; valid_feedback_entry)
                and ((.raw_findings // []) | type) == "array"
                and all((.raw_findings // [])[]; valid_raw_finding)
                and ((.finding_groups // []) | type) == "array"
                and all((.finding_groups // [])[]; valid_finding_group)
                and ((active_mainlines | length) <= 1)
                and (
                    if (active_mainlines | length) == 1 then
                        (.manager.current_primary_task_id // null) == active_mainlines[0].id
                    elif (.manager.current_primary_task_id // null) == null then
                        true
                    else
                        true
                    end
                )
                and all(.tasks[]; ((.authority.authoritative_source // "manager") == "manager"))
            else
                true
            end
        )
    ' "$matrix_file" >/dev/null 2>&1
}

scenario_matrix_dependency_hint_from_review() {
    local review_content_lower
    review_content_lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')

    if printf '%s\n' "$review_content_lower" | grep -qE 'depends on|dependency|dependent task|downstream|upstream|interface chang|contract chang|schema chang|follow-on task'; then
        echo "true"
    else
        echo "false"
    fi
}

scenario_matrix_extract_review_coverage_json() {
    local review_content="$1"
    local current_section=""
    local trimmed heading_candidate normalized_header section_end=false
    local surfaces_json='[]'
    local sibling_json='[]'
    local coverage_json='[]'
    local -a surface_lines=()
    local -a sibling_lines=()
    local -a coverage_lines=()
    local coverage_paragraph=""
    local line content surface reason confidence summary derived_from expansion_axis why_likely recommended_check
    local -a parts=()
    local cell_lines row_json cells_output coverage_entry_json

    while IFS= read -r line; do
        trimmed=$(scenario_matrix_trim "$line")
        if [[ -z "$trimmed" ]]; then
            if [[ "$current_section" == "coverage" && -n "$coverage_paragraph" ]]; then
                coverage_entry_json=$(scenario_matrix_parse_coverage_ledger_paragraph_json "$coverage_paragraph")
                if [[ -n "$coverage_entry_json" ]]; then
                    coverage_json=$(jq -cn --argjson rows "$coverage_json" --argjson row "$coverage_entry_json" '$rows + [$row]')
                fi
                coverage_paragraph=""
            fi
            continue
        fi

        if [[ "$trimmed" == "COMPLETE" || "$trimmed" == "CONTINUE" || "$trimmed" == "STOP" ]]; then
            if [[ "$current_section" == "coverage" && -n "$coverage_paragraph" ]]; then
                coverage_entry_json=$(scenario_matrix_parse_coverage_ledger_paragraph_json "$coverage_paragraph")
                if [[ -n "$coverage_entry_json" ]]; then
                    coverage_json=$(jq -cn --argjson rows "$coverage_json" --argjson row "$coverage_entry_json" '$rows + [$row]')
                fi
                coverage_paragraph=""
            fi
            current_section=""
            continue
        fi

        heading_candidate=$(printf '%s' "$trimmed" | sed 's/^#\{1,6\}[[:space:]]*//')
        normalized_header=$(scenario_matrix_normalize_header "$heading_candidate")
        case "$normalized_header" in
            "touched failure surfaces")
                if [[ "$current_section" == "coverage" && -n "$coverage_paragraph" ]]; then
                    coverage_entry_json=$(scenario_matrix_parse_coverage_ledger_paragraph_json "$coverage_paragraph")
                    if [[ -n "$coverage_entry_json" ]]; then
                        coverage_json=$(jq -cn --argjson rows "$coverage_json" --argjson row "$coverage_entry_json" '$rows + [$row]')
                    fi
                    coverage_paragraph=""
                fi
                current_section="surfaces"
                continue
                ;;
            "likely sibling risks")
                if [[ "$current_section" == "coverage" && -n "$coverage_paragraph" ]]; then
                    coverage_entry_json=$(scenario_matrix_parse_coverage_ledger_paragraph_json "$coverage_paragraph")
                    if [[ -n "$coverage_entry_json" ]]; then
                        coverage_json=$(jq -cn --argjson rows "$coverage_json" --argjson row "$coverage_entry_json" '$rows + [$row]')
                    fi
                    coverage_paragraph=""
                fi
                current_section="siblings"
                continue
                ;;
            "coverage ledger")
                current_section="coverage"
                continue
                ;;
            "mainline gaps"|"blocking side issues"|"queued side issues"|"goal alignment summary")
                if [[ "$current_section" == "coverage" && -n "$coverage_paragraph" ]]; then
                    coverage_entry_json=$(scenario_matrix_parse_coverage_ledger_paragraph_json "$coverage_paragraph")
                    if [[ -n "$coverage_entry_json" ]]; then
                        coverage_json=$(jq -cn --argjson rows "$coverage_json" --argjson row "$coverage_entry_json" '$rows + [$row]')
                    fi
                    coverage_paragraph=""
                fi
                current_section=""
                continue
                ;;
        esac

        if [[ "$trimmed" =~ ^Mainline[[:space:]]+Progress[[:space:]]+Verdict: ]]; then
            if [[ "$current_section" == "coverage" && -n "$coverage_paragraph" ]]; then
                coverage_entry_json=$(scenario_matrix_parse_coverage_ledger_paragraph_json "$coverage_paragraph")
                if [[ -n "$coverage_entry_json" ]]; then
                    coverage_json=$(jq -cn --argjson rows "$coverage_json" --argjson row "$coverage_entry_json" '$rows + [$row]')
                fi
                coverage_paragraph=""
            fi
            current_section=""
            continue
        fi

        case "$current_section" in
            surfaces)
                surface_lines+=("$trimmed")
                if [[ "$trimmed" =~ ^[*-][[:space:]]+ ]]; then
                    content=$(printf '%s' "$trimmed" | sed 's/^[*-][[:space:]]*//')
                    surface=$(scenario_matrix_trim "${content%%|*}")
                    reason=""
                    confidence=""
                    if [[ "$content" == *"|"* ]]; then
                        IFS='|' read -r -a parts <<< "$content"
                        surface=$(scenario_matrix_trim "${parts[0]:-}")
                        for part in "${parts[@]:1}"; do
                            part=$(scenario_matrix_trim "$part")
                            case "$(printf '%s' "$part" | tr '[:upper:]' '[:lower:]')" in
                                why:*)
                                    reason=$(scenario_matrix_trim "${part#*:}")
                                    ;;
                                confidence:*)
                                    confidence=$(scenario_matrix_trim "${part#*:}")
                                    ;;
                            esac
                        done
                    fi
                    if [[ -n "$surface" ]]; then
                        row_json=$(jq -cn \
                            --arg surface "$surface" \
                            --arg reason "$reason" \
                            --arg confidence "$confidence" \
                            '{
                                surface: $surface,
                                reason: $reason,
                                confidence: (if $confidence == "" then null else $confidence end)
                            }')
                        surfaces_json=$(jq -cn --argjson rows "$surfaces_json" --argjson row "$row_json" '$rows + [$row]')
                    fi
                fi
                ;;
            siblings)
                sibling_lines+=("$trimmed")
                if [[ "$trimmed" =~ ^[*-][[:space:]]+ ]]; then
                    content=$(printf '%s' "$trimmed" | sed 's/^[*-][[:space:]]*//')
                    summary=$(scenario_matrix_trim "${content%%|*}")
                    derived_from=""
                    expansion_axis=""
                    why_likely=""
                    recommended_check=""
                    confidence=""
                    if [[ "$content" == *"|"* ]]; then
                        IFS='|' read -r -a parts <<< "$content"
                        summary=$(scenario_matrix_trim "${parts[0]:-}")
                        for part in "${parts[@]:1}"; do
                            part=$(scenario_matrix_trim "$part")
                            case "$(printf '%s' "$part" | tr '[:upper:]' '[:lower:]')" in
                                derived_from:*|derived-from:*)
                                    derived_from=$(scenario_matrix_trim "${part#*:}")
                                    ;;
                                axis:*)
                                    expansion_axis=$(scenario_matrix_trim "${part#*:}")
                                    ;;
                                why:*)
                                    why_likely=$(scenario_matrix_trim "${part#*:}")
                                    ;;
                                check:*|recommended_check:*|recommended-check:*)
                                    recommended_check=$(scenario_matrix_trim "${part#*:}")
                                    ;;
                                confidence:*)
                                    confidence=$(scenario_matrix_trim "${part#*:}")
                                    ;;
                            esac
                        done
                    fi
                    if [[ -n "$summary" ]]; then
                        row_json=$(jq -cn \
                            --arg summary "$summary" \
                            --arg derived_from "$derived_from" \
                            --arg expansion_axis "$expansion_axis" \
                            --arg why_likely "$why_likely" \
                            --arg recommended_check "$recommended_check" \
                            --arg confidence "$confidence" \
                            '{
                                summary: $summary,
                                derived_from: (if $derived_from == "" then null else $derived_from end),
                                expansion_axis: (if $expansion_axis == "" then null else $expansion_axis end),
                                why_likely: (if $why_likely == "" then null else $why_likely end),
                                recommended_check: (if $recommended_check == "" then null else $recommended_check end),
                                confidence: (if $confidence == "" then null else $confidence end)
                            }')
                        sibling_json=$(jq -cn --argjson rows "$sibling_json" --argjson row "$row_json" '$rows + [$row]')
                    fi
                fi
                ;;
            coverage)
                coverage_lines+=("$trimmed")
                if [[ "$trimmed" == \|* ]]; then
                    if [[ -n "$coverage_paragraph" ]]; then
                        coverage_entry_json=$(scenario_matrix_parse_coverage_ledger_paragraph_json "$coverage_paragraph")
                        if [[ -n "$coverage_entry_json" ]]; then
                            coverage_json=$(jq -cn --argjson rows "$coverage_json" --argjson row "$coverage_entry_json" '$rows + [$row]')
                        fi
                        coverage_paragraph=""
                    fi
                    if printf '%s\n' "$trimmed" | grep -qE '^[[:space:]|:-]+$'; then
                        continue
                    fi
                    cells_output=$(scenario_matrix_row_to_cells "$trimmed")
                    scenario_matrix_read_lines_into_array parts "$cells_output"
                    surface=$(scenario_matrix_trim "${parts[0]:-}")
                    if [[ "$(printf '%s' "$surface" | tr '[:upper:]' '[:lower:]')" == "surface" ]]; then
                        continue
                    fi
                    if [[ -n "$surface" ]]; then
                        row_json=$(jq -cn \
                            --arg surface "$surface" \
                            --arg status "$(scenario_matrix_trim "${parts[1]:-}")" \
                            --arg notes "$(scenario_matrix_trim "${parts[2]:-}")" \
                            '{
                                surface: $surface,
                                status: (if $status == "" then "unclear" else $status end),
                                notes: $notes
                            }')
                        coverage_json=$(jq -cn --argjson rows "$coverage_json" --argjson row "$row_json" '$rows + [$row]')
                    fi
                else
                    if [[ -n "$coverage_paragraph" ]]; then
                        coverage_paragraph+=$'\n'
                    fi
                    coverage_paragraph+="$trimmed"
                fi
                ;;
        esac
    done <<< "$review_content"

    if [[ "$current_section" == "coverage" && -n "$coverage_paragraph" ]]; then
        coverage_entry_json=$(scenario_matrix_parse_coverage_ledger_paragraph_json "$coverage_paragraph")
        if [[ -n "$coverage_entry_json" ]]; then
            coverage_json=$(jq -cn --argjson rows "$coverage_json" --argjson row "$coverage_entry_json" '$rows + [$row]')
        fi
    fi

    jq -cn \
        --argjson touched_failure_surfaces "$surfaces_json" \
        --argjson likely_sibling_risks "$sibling_json" \
        --argjson coverage_ledger "$coverage_json" \
        --arg touched_raw "$(scenario_matrix_lines_to_json_string "${surface_lines[@]}")" \
        --arg sibling_raw "$(scenario_matrix_lines_to_json_string "${sibling_lines[@]}")" \
        --arg coverage_raw "$(scenario_matrix_lines_to_json_string "${coverage_lines[@]}")" '
        {
            touched_failure_surfaces: $touched_failure_surfaces,
            likely_sibling_risks: $likely_sibling_risks,
            coverage_ledger: $coverage_ledger,
            raw_sections: {
                touched_failure_surfaces: (
                    try ($touched_raw | fromjson) catch ""
                ),
                likely_sibling_risks: (
                    try ($sibling_raw | fromjson) catch ""
                ),
                coverage_ledger: (
                    try ($coverage_raw | fromjson) catch ""
                )
            },
            summary: {
                surface_count: ($touched_failure_surfaces | length),
                sibling_risk_count: ($likely_sibling_risks | length),
                covered_count: ([ $coverage_ledger[] | select(((.status // "") | ascii_downcase) == "covered") ] | length),
                partial_or_unclear_count: ([ $coverage_ledger[] | select(((.status // "") | ascii_downcase) == "partial" or ((.status // "") | ascii_downcase) == "unclear") ] | length)
            }
        }'
}

scenario_matrix_record_feedback() {
    local matrix_file="$1"
    local feedback_channel="$2"
    local task_id="${3:-}"
    local suggested_by="${4:-}"
    local feedback_kind="${5:-}"
    local feedback_summary="${6:-}"

    if ! scenario_matrix_validate_file "$matrix_file"; then
        return 1
    fi

    if [[ "$feedback_channel" != "execution" && "$feedback_channel" != "review" ]]; then
        return 1
    fi

    local created_at temp_file
    created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    temp_file="${matrix_file}.tmp.$$"

    jq \
        --arg feedback_channel "$feedback_channel" \
        --arg task_id "${task_id:-}" \
        --arg suggested_by "${suggested_by:-unknown}" \
        --arg feedback_kind "${feedback_kind:-note}" \
        --arg feedback_summary "$feedback_summary" \
        --arg created_at "$created_at" '
        .feedback = (.feedback // {execution: [], review: []})
        | .feedback[$feedback_channel] = (.feedback[$feedback_channel] // [])
        | .feedback[$feedback_channel] += [
            {
                source: $feedback_channel,
                kind: $feedback_kind,
                task_id: (if $task_id == "" then null else $task_id end),
                summary: $feedback_summary,
                suggested_by: $suggested_by,
                source_file: null,
                created_at: $created_at,
                authoritative: false
            }
        ]
    ' "$matrix_file" > "$temp_file" && mv "$temp_file" "$matrix_file"
}

scenario_matrix_record_execution_feedback() {
    scenario_matrix_record_feedback "$1" "execution" "${2:-}" "${3:-}" "${4:-}" "${5:-}"
}

scenario_matrix_record_review_feedback() {
    scenario_matrix_record_feedback "$1" "review" "${2:-}" "${3:-}" "${4:-}" "${5:-}"
}

scenario_matrix_current_primary_task_id() {
    local matrix_file="$1"

    if ! scenario_matrix_validate_file "$matrix_file"; then
        return 1
    fi

    jq -r '
        if (.manager.current_primary_task_id // null) != null then
            .manager.current_primary_task_id
        else
            (
                first(
                    .tasks[]
                    | select(.lane == "mainline")
                    | select(.state != "done" and .state != "deferred")
                    | .id
                ) // empty
            )
        end
    ' "$matrix_file"
}

scenario_matrix_render_task_packet_markdown() {
    local matrix_file="$1"
    local task_id="${2:-}"

    if ! scenario_matrix_validate_file "$matrix_file"; then
        return 1
    fi

    jq -r --arg task_id "$task_id" '
        . as $root
        | def clean_text:
            tostring
            | gsub("\\|"; "/")
            | gsub("\\r?\\n"; " ");
        def active_task:
            first(
                $root.tasks[]
                | select(.lane == "mainline")
                | select(.state != "done" and .state != "deferred")
            );
        def packet_task:
            if $task_id != "" then
                first($root.tasks[] | select(.id == $task_id))
            elif ($root.manager.current_primary_task_id // null) != null then
                first($root.tasks[] | select(.id == $root.manager.current_primary_task_id))
            else
                active_task
            end;
        def target_task: packet_task;
        def downstream_ids($id):
            [
                $root.tasks[]
                | select((.depends_on // []) | index($id))
                | .id
            ];
        def cluster_label($task):
            if ($task.cluster_id // null) != null then
                $task.cluster_id
            elif ($task.repair_wave // null) != null then
                $task.repair_wave
            else
                "none"
            end;
        def scope_summary($task):
            if (($task.scope.summary // "") | length) > 0 then
                $task.scope.summary
            else
                "Stay within the current scenario matrix frontier and do not widen into unrelated queued work."
            end;
        def scope_paths($task):
            if (($task.scope.paths // []) | length) > 0 then
                (($task.scope.paths // []) | join(", "))
            else
                "unspecified"
            end;
        def protected_constraints($task):
            (
                (($task.scope.constraints // []) + ($task.assumptions // []))
                | map(clean_text)
            ) as $items
            | if ($items | length) > 0 then
                ($items | join("; "))
              else
                "Keep dependencies, tracker alignment, and the single-mainline objective intact."
              end;
        def success_criteria($task):
            if ($task.state == "needs_replan") then
                "Produce a narrower recovery step for " + ($task.id // "task") + " without broadening scope."
            elif $task.state == "blocked" then
                "Unblock " + ($task.id // "task") + " by resolving the required upstream dependency without widening scope."
            else
                "Advance " + ($task.id // "task") + " toward " + (($task.target_ac // []) | join(", ")) + " without widening scope beyond the current frontier."
            end;
        def stop_criteria($task):
            "Stop and report back if progress would require widening scope, changing unrelated tasks, or invalidating an upstream/downstream dependency assumption.";
        def out_of_scope($task):
            (
                [
                    $root.tasks[]
                    | .id as $other_task_id
                    | select(.id != ($task.id // ""))
                    | select(.state != "done" and .state != "deferred")
                    | select(.lane != "mainline")
                    | select((($root.runtime.checkpoint.supporting_task_ids // []) | index($other_task_id)) == null)
                    | select(.state != "blocked" and .state != "needs_replan")
                    | ($other_task_id + ": " + (.title | clean_text))
                ]
            ) as $other_open
            | if ($other_open | length) > 0 then
                ($other_open | join("; "))
              else
                "Any unrelated follow-up outside the assigned task packet."
              end;

        if (target_task | type) == "object" then
            "## Current Task Packet\n\n"
            + "- Primary Objective: `"
            + (($root.manager.current_primary_task_id // target_task.id // "unknown") | clean_text)
            + "`"
            + (if (($root.manager.current_primary_task_id // null) != null and ($root.manager.current_primary_task_id != target_task.id)) then
                " (this packet is delegated from the current primary objective)"
              else
                ""
              end)
            + "\n- Assigned Task: `"
            + ((target_task.id // "unknown") | clean_text)
            + "` - "
            + ((target_task.title // "Untitled task") | clean_text)
            + "\n- Cluster / Repair Wave: `"
            + (cluster_label(target_task) | clean_text)
            + "`"
            + "\n- Direct Upstream Dependencies: "
            + (
                if ((target_task.depends_on // []) | length) > 0 then
                    ((target_task.depends_on // []) | join(", "))
                else
                    "none"
                end
            )
            + "\n- Direct Downstream Impact: "
            + (
                if (downstream_ids(target_task.id) | length) > 0 then
                    (downstream_ids(target_task.id) | join(", "))
                else
                    "none"
                end
            )
            + "\n- Target ACs: "
            + (
                if ((target_task.target_ac // []) | length) > 0 then
                    ((target_task.target_ac // []) | join(", "))
                else
                    "-"
                end
            )
            + "\n- Risk Bucket: `"
            + ((target_task.risk_bucket // "normal") | clean_text)
            + "`"
            + "\n- Allowed Scope Summary: "
            + (scope_summary(target_task) | clean_text)
            + "\n- Allowed Scope Paths: "
            + (scope_paths(target_task) | clean_text)
            + "\n- Protected Constraints: "
            + (protected_constraints(target_task) | clean_text)
            + "\n- Success Criteria: "
            + (success_criteria(target_task) | clean_text)
            + "\n- Stop Criteria: "
            + (stop_criteria(target_task) | clean_text)
            + "\n- Out Of Scope: "
            + (out_of_scope(target_task) | clean_text)
            + "\n\nIf you delegate work to a subagent, project these same packet fields and narrow the scope instead of dropping the global context."
        else
            empty
        end
    ' "$matrix_file"
}

scenario_matrix_current_task_packet_markdown() {
    scenario_matrix_render_task_packet_markdown "$1" ""
}

scenario_matrix_task_packet_feedback_instructions_markdown() {
    cat <<'EOF'
## Task Packet Feedback Readback

If you delegated work or learned packet-relevant context that should influence future scheduling, record it in your summary under:

## Task Packet Feedback
| Task ID | Source | Kind | Summary |
|---------|--------|------|---------|

Allowed `Kind` values:
- `state_suggestion`
- `scope_update`
- `dependency_note`
- `cluster_hint`
- `stop_note`

Only record non-authoritative observations or suggestions there. Do not treat them as direct task-state edits.
EOF
}

scenario_matrix_extract_task_packet_feedback_section() {
    local summary_file="$1"

    awk '
        /^##[[:space:]]*Task Packet Feedback([[:space:]]*$|[[:space:][:punct:]].*)/ {
            in_section = 1
            next
        }
        /^##[[:space:]]+/ {
            if (in_section) {
                exit
            }
        }
        in_section {
            print
        }
    ' "$summary_file"
}

scenario_matrix_parse_task_packet_feedback_json() {
    local summary_file="$1"
    local section

    section=$(scenario_matrix_extract_task_packet_feedback_section "$summary_file")
    if [[ -z "$section" ]]; then
        printf '[]\n'
        return 0
    fi

    local -a table_lines=()
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*\| ]] || continue
        table_lines+=("$line")
    done <<< "$section"

    if [[ ${#table_lines[@]} -lt 2 ]]; then
        printf '[]\n'
        return 0
    fi

    local -a header_cells=()
    scenario_matrix_read_lines_into_array header_cells "$(scenario_matrix_row_to_cells "${table_lines[0]}")"

    local idx_task_id=-1
    local idx_source=-1
    local idx_kind=-1
    local idx_summary=-1
    local i normalized_header
    for i in "${!header_cells[@]}"; do
        normalized_header=$(scenario_matrix_normalize_header "${header_cells[$i]}")
        case "$normalized_header" in
            "task id")
                idx_task_id=$i
                ;;
            "source")
                idx_source=$i
                ;;
            "kind")
                idx_kind=$i
                ;;
            "summary")
                idx_summary=$i
                ;;
        esac
    done

    if [[ $idx_task_id -lt 0 || $idx_source -lt 0 || $idx_kind -lt 0 || $idx_summary -lt 0 ]]; then
        printf '[]\n'
        return 0
    fi

    local entries_json='[]'
    local task_id source kind summary row_number
    for ((i = 2; i < ${#table_lines[@]}; i++)); do
        local -a row_cells=()
        scenario_matrix_read_lines_into_array row_cells "$(scenario_matrix_row_to_cells "${table_lines[$i]}")"
        row_number=$i

        task_id=$(scenario_matrix_trim "${row_cells[$idx_task_id]:-}")
        source=$(scenario_matrix_trim "${row_cells[$idx_source]:-}")
        kind=$(scenario_matrix_trim "${row_cells[$idx_kind]:-}")
        summary=$(scenario_matrix_trim "${row_cells[$idx_summary]:-}")

        if [[ -z "$task_id" && -z "$source" && -z "$kind" && -z "$summary" ]]; then
            continue
        fi

        if [[ -z "$task_id" || -z "$source" || -z "$kind" || -z "$summary" ]]; then
            continue
        fi

        if [[ ! "$task_id" =~ ^[a-zA-Z0-9._-]+$ ]]; then
            continue
        fi

        entries_json=$(jq -cn \
            --argjson entries "$entries_json" \
            --arg task_id "$task_id" \
            --arg source "$source" \
            --arg kind "$kind" \
            --arg summary "$summary" \
            '$entries + [{
                task_id: $task_id,
                suggested_by: $source,
                kind: $kind,
                summary: $summary
            }]')
    done

    printf '%s\n' "$entries_json"
}

scenario_matrix_ingest_summary_feedback() {
    local matrix_file="$1"
    local summary_file="$2"

    if ! scenario_matrix_validate_file "$matrix_file"; then
        return 1
    fi

    if [[ ! -f "$summary_file" ]]; then
        return 0
    fi

    local feedback_json source_file created_at temp_file
    feedback_json=$(scenario_matrix_parse_task_packet_feedback_json "$summary_file")
    source_file=$(basename "$summary_file")
    created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    temp_file="${matrix_file}.tmp.$$"

    jq \
        --arg source_file "$source_file" \
        --arg created_at "$created_at" \
        --argjson feedback_json "$feedback_json" '
        .feedback = (.feedback // {execution: [], review: []})
        | .feedback.execution = (
            (.feedback.execution // [])
            | map(select((.source_file // "") != $source_file))
        )
        | .feedback.execution += (
            $feedback_json
            | map(
                . + {
                    source: "execution",
                    source_file: $source_file,
                    created_at: $created_at,
                    authoritative: false
                }
            )
        )
    ' "$matrix_file" > "$temp_file" && mv "$temp_file" "$matrix_file"
}

scenario_matrix_slugify() {
    printf '%s' "$1" \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/[^a-z0-9][^a-z0-9]*/-/g; s/^-//; s/-$//; s/-\{2,\}/-/g'
}

scenario_matrix_normalize_finding_key() {
    local normalized
    normalized=$(scenario_matrix_slugify "$1")
    if [[ -n "$normalized" ]]; then
        printf '%s\n' "$normalized"
    else
        printf 'finding\n'
    fi
}

scenario_matrix_severity_rank() {
    local severity
    severity=$(printf '%s' "${1:-P4}" | tr '[:upper:]' '[:lower:]')
    case "$severity" in
        p0) echo 0 ;;
        p1) echo 1 ;;
        p2) echo 2 ;;
        p3) echo 3 ;;
        *) echo 4 ;;
    esac
}

scenario_matrix_guess_review_kind() {
    local summary_lower
    summary_lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')

    if printf '%s\n' "$summary_lower" | grep -qE 'investigat|question|clarif|unknown|analy[sz]e'; then
        echo "investigation"
    elif printf '%s\n' "$summary_lower" | grep -qE 'test|validation|assert|coverage|fixture|smoke|regression'; then
        echo "validation"
    elif printf '%s\n' "$summary_lower" | grep -qE 'cleanup|style|format|typo|wording|docs?|readme|comment|nit'; then
        echo "cleanup"
    else
        echo "defect"
    fi
}

scenario_matrix_guess_review_confidence() {
    case "$(scenario_matrix_severity_rank "$1")" in
        0) echo "0.98" ;;
        1) echo "0.92" ;;
        2) echo "0.80" ;;
        3) echo "0.65" ;;
        *) echo "0.55" ;;
    esac
}

scenario_matrix_guess_review_cluster() {
    local summary_lower
    summary_lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')

    if printf '%s\n' "$summary_lower" | grep -qE 'depend|downstream|upstream|contract|interface|schema|parser|validator'; then
        echo "dependency-contract"
    elif printf '%s\n' "$summary_lower" | grep -qE 'test|validation|assert|coverage|fixture|smoke|regression'; then
        echo "validation"
    elif printf '%s\n' "$summary_lower" | grep -qE 'monitor|prompt|tracker|matrix|hook|finalize'; then
        echo "runtime-surface"
    elif printf '%s\n' "$summary_lower" | grep -qE 'docs?|readme|wording|comment|typo'; then
        echo "docs-cleanup"
    elif printf '%s\n' "$summary_lower" | grep -qE 'cleanup|style|format|lint|rename|refactor'; then
        echo "cleanup"
    elif printf '%s\n' "$summary_lower" | grep -qE 'investigat|question|clarif'; then
        echo "investigation"
    else
        echo "general-review"
    fi
}

scenario_matrix_guess_review_admission_status() {
    local phase="$1"
    local severity="$2"
    local kind="$3"
    local section="$4"
    local summary_lower
    local severity_rank

    summary_lower=$(printf '%s' "$5" | tr '[:upper:]' '[:lower:]')
    severity_rank=$(scenario_matrix_severity_rank "$severity")

    if [[ "$section" == "queued" || "$kind" == "cleanup" ]]; then
        echo "watchlist"
    elif printf '%s\n' "$summary_lower" | grep -qE 'docs?-only|wording|typo|comment|nit|style|format'; then
        echo "watchlist"
    elif [[ "$severity_rank" -ge 3 ]]; then
        echo "watchlist"
    elif [[ "$phase" == "implementation" && "$section" == "queued" ]]; then
        echo "watchlist"
    else
        echo "active"
    fi
}

scenario_matrix_guess_review_admission_reason() {
    local phase="$1"
    local admission_status="$2"
    local section="$3"

    if [[ "$admission_status" == "watchlist" ]]; then
        echo "low_impact_or_out_of_scope"
    elif [[ "$phase" == "review" ]]; then
        echo "review_blocking"
    elif [[ "$section" == "blocking" ]]; then
        echo "blocking_follow_up"
    else
        echo "review_follow_up"
    fi
}

scenario_matrix_guess_review_state() {
    local phase="$1"
    local severity="$2"
    local section="$3"
    local admission_status="$4"
    local severity_rank

    severity_rank=$(scenario_matrix_severity_rank "$severity")

    if [[ "$admission_status" == "watchlist" ]]; then
        echo "deferred"
    elif [[ "$phase" == "review" || "$section" == "blocking" || "$severity_rank" -le 1 ]]; then
        echo "blocked"
    elif [[ "$section" == "mainline_gaps" ]]; then
        echo "needs_replan"
    else
        echo "pending"
    fi
}

scenario_matrix_guess_review_lane() {
    if [[ "$1" == "watchlist" ]]; then
        echo "queued"
    else
        echo "supporting"
    fi
}

scenario_matrix_guess_review_routing() {
    if [[ "$1" == "investigation" ]]; then
        echo "analyze"
    else
        echo "coding"
    fi
}

scenario_matrix_has_task_id() {
    local matrix_file="$1"
    local task_id="$2"

    jq -e --arg task_id "$task_id" '.tasks | any(.[]; .id == $task_id)' "$matrix_file" >/dev/null 2>&1
}

scenario_matrix_summary_mentions_task_id() {
    local summary="$1"
    local task_id="$2"
    local remainder prefix match_start before_char after_char

    [[ -z "$summary" || -z "$task_id" ]] && return 1

    remainder="$summary"
    while [[ "$remainder" == *"$task_id"* ]]; do
        prefix="${remainder%%"$task_id"*}"
        match_start=${#prefix}
        before_char=""
        after_char=""

        if [[ "$match_start" -gt 0 ]]; then
            before_char="${remainder:$((match_start - 1)):1}"
        fi
        if [[ $((match_start + ${#task_id})) -lt ${#remainder} ]]; then
            after_char="${remainder:$((match_start + ${#task_id})):1}"
        fi

        if [[ ! "$before_char" =~ [[:alnum:]_.-] ]] && [[ ! "$after_char" =~ [[:alnum:]_.-] ]]; then
            return 0
        fi

        remainder="${remainder:$((match_start + 1))}"
    done

    return 1
}

scenario_matrix_find_explicit_task_reference() {
    local matrix_file="$1"
    local summary="$2"
    local summary_lower task_id task_id_lower

    summary_lower=$(printf '%s' "$summary" | tr '[:upper:]' '[:lower:]')

    while IFS= read -r task_id; do
        [[ -z "$task_id" ]] && continue
        if scenario_matrix_summary_mentions_task_id "$summary" "$task_id"; then
            printf '%s\n' "$task_id"
            return 0
        fi

        task_id_lower=$(printf '%s' "$task_id" | tr '[:upper:]' '[:lower:]')
        if [[ "$task_id_lower" != "$task_id" ]] && scenario_matrix_summary_mentions_task_id "$summary_lower" "$task_id_lower"; then
            printf '%s\n' "$task_id"
            return 0
        fi
    done < <(jq -r '.tasks[]?.id // empty' "$matrix_file")

    return 1
}

scenario_matrix_task_target_ac_json() {
    local matrix_file="$1"
    local task_id="$2"

    if [[ -z "$task_id" ]]; then
        printf '[]\n'
        return 0
    fi

    jq -c --arg task_id "$task_id" '
        first(.tasks[] | select(.id == $task_id) | (.target_ac // [])) // []
    ' "$matrix_file"
}

scenario_matrix_is_dependency_related_summary() {
    local summary_lower
    summary_lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    if printf '%s\n' "$summary_lower" | grep -qE 'depend|downstream|upstream|contract|interface|schema|validator'; then
        return 0
    fi
    return 1
}

scenario_matrix_infer_related_task_id() {
    local matrix_file="$1"
    local summary="$2"
    local primary_task_id="${3:-}"
    local summary_lower

    summary_lower=$(printf '%s' "$summary" | tr '[:upper:]' '[:lower:]')
    if [[ -n "$primary_task_id" ]] && scenario_matrix_is_dependency_related_summary "$summary"; then
        local dependent_count dependent_task_id
        dependent_count=$(jq -r --arg primary_task_id "$primary_task_id" '
            [
                .tasks[]
                | select(.id != $primary_task_id)
                | select(((.depends_on // []) | index($primary_task_id)) != null)
                | .id
            ] | length
        ' "$matrix_file")

        if [[ "$dependent_count" == "1" ]]; then
            dependent_task_id=$(jq -r --arg primary_task_id "$primary_task_id" '
                first(
                    .tasks[]
                    | select(.id != $primary_task_id)
                    | select(((.depends_on // []) | index($primary_task_id)) != null)
                    | .id
                ) // empty
            ' "$matrix_file")
            if [[ -n "$dependent_task_id" ]]; then
                printf '%s\n' "$dependent_task_id"
                return 0
            fi
        elif [[ "$dependent_count" != "0" ]]; then
            # When multiple dependent tasks could match the same finding, keep it
            # as a standalone bounded task instead of mutating the wrong dependent.
            return 0
        fi
    fi

    if [[ -n "$primary_task_id" ]]; then
        printf '%s\n' "$primary_task_id"
    fi
}

scenario_matrix_build_generated_task_id() {
    local matrix_file="$1"
    local round="$2"
    local finding_index="$3"
    local finding_key="$4"
    local slug base_id candidate suffix

    slug=$(scenario_matrix_normalize_finding_key "$finding_key")
    slug=${slug:0:24}
    base_id="finding-r${round}-f${finding_index}"
    if [[ -n "$slug" ]]; then
        base_id="${base_id}-${slug}"
    fi

    candidate="$base_id"
    suffix=2
    while scenario_matrix_has_task_id "$matrix_file" "$candidate"; do
        candidate="${base_id}-${suffix}"
        suffix=$((suffix + 1))
    done

    printf '%s\n' "$candidate"
}

scenario_matrix_extract_review_findings_json() {
    local matrix_file="$1"
    local round="$2"
    local review_phase="$3"
    local review_content="$4"
    local primary_task_id current_section findings_json finding_index
    local line trimmed trimmed_lower severity summary file_ref kind confidence
    local cluster_key cluster_id repair_wave admission_status admission_reason
    local lane state routing related_task_id link_task_id target_ac_json
    local depends_on_json finding_key task_id event_id explicit_task_id

    if ! scenario_matrix_validate_file "$matrix_file"; then
        return 1
    fi

    primary_task_id=$(scenario_matrix_current_primary_task_id "$matrix_file" 2>/dev/null || true)
    current_section=""
    findings_json='[]'
    finding_index=0

    while IFS= read -r line; do
        trimmed=$(scenario_matrix_trim "$line")
        [[ -z "$trimmed" ]] && continue

        trimmed_lower=$(printf '%s' "$trimmed" | tr '[:upper:]' '[:lower:]')
        case "$trimmed_lower" in
            "## mainline gaps"*|"mainline gaps"*)
                current_section="mainline_gaps"
                continue
                ;;
            "## blocking side issues"*|"blocking side issues"*)
                current_section="blocking"
                continue
                ;;
            "## queued side issues"*|"queued side issues"*)
                current_section="queued"
                continue
                ;;
        esac

        severity=""
        summary=""
        file_ref=""
        if [[ "$trimmed" =~ ^[*-]?[[:space:]]*\[(P[0-9]+)\][[:space:]]*(.+)$ ]]; then
            severity="${BASH_REMATCH[1]}"
            summary="${BASH_REMATCH[2]}"
        elif [[ -n "$current_section" && "$trimmed" =~ ^[*-][[:space:]]+(.+)$ ]]; then
            summary="${BASH_REMATCH[1]}"
            case "$current_section" in
                blocking) severity="P1" ;;
                queued) severity="P3" ;;
                *) severity="P2" ;;
            esac
        else
            continue
        fi

        summary=$(scenario_matrix_trim "$summary")
        if [[ "$summary" =~ ^(.*)[[:space:]]-[[:space:]](\/[^[:space:]]+:[0-9][0-9:-]*)$ ]]; then
            summary=$(scenario_matrix_trim "${BASH_REMATCH[1]}")
            file_ref="${BASH_REMATCH[2]}"
        fi
        [[ -z "$summary" ]] && continue

        kind=$(scenario_matrix_guess_review_kind "$summary")
        confidence=$(scenario_matrix_guess_review_confidence "$severity")
        cluster_key=$(scenario_matrix_guess_review_cluster "$summary")
        cluster_id="cluster-${cluster_key}"
        repair_wave="wave-r${round}-${cluster_key}"
        admission_status=$(scenario_matrix_guess_review_admission_status "$review_phase" "$severity" "$kind" "$current_section" "$summary")
        admission_reason=$(scenario_matrix_guess_review_admission_reason "$review_phase" "$admission_status" "$current_section")
        lane=$(scenario_matrix_guess_review_lane "$admission_status")
        state=$(scenario_matrix_guess_review_state "$review_phase" "$severity" "$current_section" "$admission_status")
        routing=$(scenario_matrix_guess_review_routing "$kind")
        explicit_task_id=$(scenario_matrix_find_explicit_task_reference "$matrix_file" "$summary" 2>/dev/null || true)
        if [[ -n "$explicit_task_id" ]]; then
            related_task_id="$explicit_task_id"
        else
            related_task_id=$(scenario_matrix_infer_related_task_id "$matrix_file" "$summary" "$primary_task_id")
        fi
        link_task_id=""
        if [[ -n "$explicit_task_id" ]]; then
            link_task_id="$explicit_task_id"
        elif [[ -n "$related_task_id" && "$related_task_id" != "$primary_task_id" ]]; then
            link_task_id="$related_task_id"
        fi

        target_ac_json=$(scenario_matrix_task_target_ac_json "$matrix_file" "${related_task_id:-$primary_task_id}")
        depends_on_json='[]'
        if [[ "$admission_status" != "watchlist" && -n "$primary_task_id" ]]; then
            depends_on_json=$(jq -cn --arg primary_task_id "$primary_task_id" '[ $primary_task_id ]')
        fi

        finding_key=$(scenario_matrix_normalize_finding_key "${summary} ${file_ref}")
        finding_index=$((finding_index + 1))
        task_id=$(scenario_matrix_build_generated_task_id "$matrix_file" "$round" "$finding_index" "$finding_key")
        event_id="evt-finding-${review_phase}-${round}-${finding_index}"

        findings_json=$(jq -cn \
            --argjson findings_json "$findings_json" \
            --arg event_id "$event_id" \
            --arg task_id "$task_id" \
            --arg title "$summary" \
            --arg summary "$summary" \
            --arg severity "$severity" \
            --argjson confidence "$confidence" \
            --arg kind "$kind" \
            --arg source "review" \
            --arg review_phase "$review_phase" \
            --arg cluster_id "$cluster_id" \
            --arg repair_wave "$repair_wave" \
            --arg admission_status "$admission_status" \
            --arg admission_reason "$admission_reason" \
            --arg lane "$lane" \
            --arg state "$state" \
            --arg routing "$routing" \
            --arg risk_bucket "$(if [[ "$(scenario_matrix_severity_rank "$severity")" -le 1 ]]; then echo "high"; elif [[ "$(scenario_matrix_severity_rank "$severity")" -eq 2 ]]; then echo "medium"; else echo "low"; fi)" \
            --arg finding_key "$finding_key" \
            --arg related_task_id "${related_task_id:-}" \
            --arg link_task_id "${link_task_id:-}" \
            --arg file_ref "${file_ref:-}" \
            --argjson target_ac "$target_ac_json" \
            --argjson depends_on "$depends_on_json" \
            '$findings_json + [{
                event_id: $event_id,
                task_id: $task_id,
                title: $title,
                summary: $summary,
                severity: $severity,
                confidence: $confidence,
                source: $source,
                kind: $kind,
                review_phase: $review_phase,
                cluster_id: $cluster_id,
                repair_wave: $repair_wave,
                admission_status: $admission_status,
                admission_reason: $admission_reason,
                lane: $lane,
                state: $state,
                routing: $routing,
                risk_bucket: $risk_bucket,
                finding_key: $finding_key,
                related_task_id: (if $related_task_id == "" then null else $related_task_id end),
                link_task_id: (if $link_task_id == "" then null else $link_task_id end),
                file_ref: (if $file_ref == "" then null else $file_ref end),
                target_ac: $target_ac,
                depends_on: $depends_on
            }]')
    done <<< "$review_content"

    printf '%s\n' "$findings_json"
}

scenario_matrix_ingest_review_findings() {
    local matrix_file="$1"
    local round="$2"
    local review_phase="$3"
    local review_content="$4"

    if ! scenario_matrix_validate_file "$matrix_file"; then
        return 1
    fi

    local findings_json created_at temp_file
    findings_json=$(scenario_matrix_extract_review_findings_json "$matrix_file" "$round" "$review_phase" "$review_content")
    if [[ "$(printf '%s' "$findings_json" | jq 'length')" -eq 0 ]]; then
        return 0
    fi

    created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    temp_file="${matrix_file}.tmp.$$"

    jq \
        --arg created_at "$created_at" \
        --arg round "$round" \
        --arg review_phase "$review_phase" \
        --argjson findings "$findings_json" '
        def review_actor:
            if $review_phase == "review" then
                "code_review"
            else
                "implementation_review"
            end;

        def severity_rank($severity):
            (($severity // "P4") | ascii_downcase) as $s
            | if $s == "p0" then 0
              elif $s == "p1" then 1
              elif $s == "p2" then 2
              elif $s == "p3" then 3
              else 4
              end;

        def higher_severity($left; $right):
            if ($left // null) == null then
                $right
            elif ($right // null) == null then
                $left
            elif severity_rank($left) <= severity_rank($right) then
                $left
            else
                $right
            end;

        def risk_rank($bucket):
            (($bucket // "planned") | ascii_downcase) as $b
            | if $b == "high" then 0
              elif $b == "medium" then 1
              elif $b == "planned" then 2
              elif $b == "low" then 3
              else 2
              end;

        def higher_risk_bucket($left; $right):
            if risk_rank($left) <= risk_rank($right) then
                ($left // "planned")
            else
                ($right // "planned")
            end;

        def review_surface_key_from_summary($summary):
            ($summary // "" | ascii_downcase) as $s
            | if $s | test("reserv|claim|release|haul|cargo|carried|carry-invariant|operate job") then
                "reservation-lifecycle"
              elif $s | test("rollback|reassign|interrupt|cancel|restore") then
                "rollback-symmetry"
              elif $s | test("conduit|payload|pipe|medium|evacuation|gas masses|liquid-to-solid|wires") then
                "conduit-medium-integrity"
              elif $s | test("thermal|temperature|heat|overpressure") then
                "thermal-state"
              elif $s | test("projection|overlay|snapshot|serializ|render kind") then
                "projection-snapshot"
              elif $s | test("place|placement|footprint|unreachable interaction|intake/output|home positions|overlap|remove mode") then
                "placement-legality"
              elif $s | test("door|movement|blocking during footprint|door closure") then
                "door-flow-consistency"
              elif $s | test("matter|mass|conservation|non-finite") then
                "resource-conservation"
              elif $s | test("generator|battery|power") then
                "power-consistency"
              elif $s | test("path|reachable") then
                "pathing-reachability"
              elif $s | test("test|validation|assert|coverage|fixture|smoke|regression") then
                "validation-coverage"
              elif $s | test("docs?|readme|wording|comment|typo") then
                "docs-cleanup"
              elif $s | test("cleanup|style|format|lint|rename|refactor") then
                "cleanup"
              elif $s | test("investigat|question|clarif") then
                "investigation"
              else
                "general-review"
              end;

        def review_surface_label($surface_key):
            if $surface_key == "reservation-lifecycle" then
                "Reservation / lifecycle backlog"
            elif $surface_key == "rollback-symmetry" then
                "Rollback symmetry backlog"
            elif $surface_key == "conduit-medium-integrity" then
                "Conduit / medium integrity backlog"
            elif $surface_key == "thermal-state" then
                "Thermal state backlog"
            elif $surface_key == "projection-snapshot" then
                "Projection / snapshot backlog"
            elif $surface_key == "placement-legality" then
                "Placement legality backlog"
            elif $surface_key == "door-flow-consistency" then
                "Door / flow consistency backlog"
            elif $surface_key == "resource-conservation" then
                "Resource conservation backlog"
            elif $surface_key == "power-consistency" then
                "Power consistency backlog"
            elif $surface_key == "pathing-reachability" then
                "Pathing / reachability backlog"
            elif $surface_key == "validation-coverage" then
                "Validation coverage backlog"
            elif $surface_key == "docs-cleanup" then
                "Docs cleanup backlog"
            elif $surface_key == "cleanup" then
                "Cleanup backlog"
            elif $surface_key == "investigation" then
                "Investigation backlog"
            else
                "General review backlog"
            end;

        def review_group_key_from_fields($related_task_id; $link_task_id; $admission_status; $summary):
            (review_surface_key_from_summary($summary)) as $surface_key
            | (if ($admission_status // "active") == "watchlist" then "watchlist" else "active" end) as $mode
            | (($link_task_id // $related_task_id // "global") | tostring) as $subject_key
            | ($mode + ":" + $subject_key + ":" + $surface_key);

        def feedback_entry($finding):
            {
                source: "review",
                kind: (
                    if $finding.admission_status == "watchlist" then
                        "watchlist_finding"
                    else
                        "structured_finding"
                    end
                ),
                task_id: ($finding.link_task_id // $finding.related_task_id // null),
                summary: $finding.summary,
                suggested_by: review_actor,
                source_file: null,
                created_at: $created_at,
                authoritative: false
            };

        def event_entry($finding):
            {
                id: $finding.event_id,
                type: "review_finding",
                round: ($round | tonumber),
                phase: $review_phase,
                task_id: ($finding.link_task_id // $finding.related_task_id // null),
                severity: $finding.severity,
                kind: $finding.kind,
                review_phase: $finding.review_phase,
                finding_key: $finding.finding_key,
                finding_id: $finding.task_id,
                group_key: review_group_key_from_fields(($finding.related_task_id // null); ($finding.link_task_id // null); $finding.admission_status; $finding.summary),
                cluster_id: $finding.cluster_id,
                repair_wave: $finding.repair_wave,
                admission_status: $finding.admission_status,
                created_at: $created_at
            };

        def is_embedded_finding_task($task):
            (($task.metadata.seed_source // "") == "review_finding")
            or (
                (($task.id // "") | startswith("finding-r"))
                and (
                    (($task.source // "") == "review")
                    or ((($task.metadata.finding_key // "") | length) > 0)
                    or ((($task.metadata.finding_summary // "") | length) > 0)
                    or ((($task.review_phase // "") | length) > 0)
                )
            );

        def raw_finding_from_task($task):
            (($task.metadata.finding_summary // $task.title // "Review finding") | tostring) as $summary
            | (review_surface_key_from_summary($summary)) as $surface_key
            | {
                id: ($task.id // "finding"),
                title: ($task.title // $summary),
                summary: $summary,
                severity: ($task.severity // null),
                confidence: ($task.confidence // null),
                source: "review",
                kind: ($task.kind // "defect"),
                review_phase: ($task.review_phase // $review_phase),
                cluster_id: ($task.cluster_id // null),
                repair_wave_hint: ($task.repair_wave // null),
                admission_status: ($task.admission.status // "active"),
                admission_reason: ($task.admission.reason // "legacy_review_finding"),
                lane: ($task.lane // "queued"),
                state: ($task.state // "blocked"),
                routing: ($task.routing // "coding"),
                risk_bucket: ($task.risk_bucket // "planned"),
                finding_key: (
                    $task.metadata.finding_key
                    // (
                        ($summary + " " + ($task.file_ref // ""))
                        | ascii_downcase
                        | gsub("[^a-z0-9._ -]"; " ")
                        | gsub("\\s+"; "-")
                        | gsub("^-|-$"; "")
                    )
                ),
                related_task_id: ($task.metadata.related_task_id // null),
                link_task_id: null,
                file_ref: ($task.file_ref // null),
                target_ac: ($task.target_ac // []),
                depends_on: ($task.depends_on // []),
                surface_key: $surface_key,
                surface_label: review_surface_label($surface_key),
                group_key: review_group_key_from_fields(($task.metadata.related_task_id // null); null; ($task.admission.status // "active"); $summary),
                first_seen_round: ($task.metadata.source_round // ($round | tonumber)),
                last_seen_round: ($task.metadata.source_round // ($round | tonumber)),
                occurrence_count: 1
            };

        def raw_finding_from_finding($finding):
            (review_surface_key_from_summary($finding.summary)) as $surface_key
            | {
                id: $finding.task_id,
                title: $finding.title,
                summary: $finding.summary,
                severity: $finding.severity,
                confidence: $finding.confidence,
                source: $finding.source,
                kind: $finding.kind,
                review_phase: $finding.review_phase,
                cluster_id: ($finding.cluster_id // null),
                repair_wave_hint: ($finding.repair_wave // null),
                admission_status: $finding.admission_status,
                admission_reason: $finding.admission_reason,
                lane: $finding.lane,
                state: $finding.state,
                routing: $finding.routing,
                risk_bucket: $finding.risk_bucket,
                finding_key: $finding.finding_key,
                related_task_id: ($finding.related_task_id // null),
                link_task_id: ($finding.link_task_id // null),
                file_ref: ($finding.file_ref // null),
                target_ac: ($finding.target_ac // []),
                depends_on: ($finding.depends_on // []),
                surface_key: $surface_key,
                surface_label: review_surface_label($surface_key),
                group_key: review_group_key_from_fields(($finding.related_task_id // null); ($finding.link_task_id // null); $finding.admission_status; $finding.summary),
                first_seen_round: ($round | tonumber),
                last_seen_round: ($round | tonumber),
                occurrence_count: 1
            };

        def merge_raw_finding($existing; $incoming):
            $existing
            | .title = $incoming.title
            | .summary = $incoming.summary
            | .severity = higher_severity(($existing.severity // null); ($incoming.severity // null))
            | .confidence = ($incoming.confidence // $existing.confidence)
            | .source = ($incoming.source // $existing.source)
            | .kind = ($incoming.kind // $existing.kind)
            | .review_phase = ($incoming.review_phase // $existing.review_phase)
            | .cluster_id = ($incoming.cluster_id // $existing.cluster_id)
            | .repair_wave_hint = ($incoming.repair_wave_hint // $existing.repair_wave_hint)
            | .admission_status = ($incoming.admission_status // $existing.admission_status)
            | .admission_reason = ($incoming.admission_reason // $existing.admission_reason)
            | .lane = ($incoming.lane // $existing.lane)
            | .state = ($incoming.state // $existing.state)
            | .routing = ($incoming.routing // $existing.routing)
            | .risk_bucket = higher_risk_bucket(($existing.risk_bucket // "planned"); ($incoming.risk_bucket // "planned"))
            | .related_task_id = ($incoming.related_task_id // $existing.related_task_id)
            | .link_task_id = ($incoming.link_task_id // $existing.link_task_id)
            | .file_ref = ($incoming.file_ref // $existing.file_ref)
            | .target_ac = (((($existing.target_ac // []) + ($incoming.target_ac // [])) | unique))
            | .depends_on = (((($existing.depends_on // []) + ($incoming.depends_on // [])) | unique))
            | .surface_key = ($incoming.surface_key // $existing.surface_key)
            | .surface_label = ($incoming.surface_label // $existing.surface_label)
            | .group_key = ($incoming.group_key // $existing.group_key)
            | .first_seen_round = ($existing.first_seen_round // ($round | tonumber))
            | .last_seen_round = ($round | tonumber)
            | .occurrence_count = (($existing.occurrence_count // 0) + 1);

        def annotate_linked_task($task; $finding):
            $task
            | (.metadata // {}) as $metadata
            | .metadata = (
                $metadata
                + {
                    last_review_round: ($round | tonumber),
                    last_review_phase: $review_phase,
                    last_review_finding_key: $finding.finding_key,
                    last_review_summary: $finding.summary,
                    review_finding_keys: (((($metadata.review_finding_keys // []) + [$finding.finding_key]) | unique)),
                    related_task_id: ($finding.related_task_id // $metadata.related_task_id // null)
                }
            )
            | if $finding.admission_status == "watchlist" then
                .
              else
                .state = $finding.state
                | .risk_bucket = higher_risk_bucket((.risk_bucket // "planned"); ($finding.risk_bucket // "planned"))
              end;

        def task_title_by_id($task_id; $tasks):
            first($tasks[] | select(.id == $task_id) | .title) // $task_id;

        def finding_group_state($items):
            if ($items | all(.[]; ((.admission_status // "active") == "watchlist") or ((.state // "") == "deferred"))) then
                "deferred"
            elif ($items | any(.[]; ((.state // "") == "blocked") or ((.state // "") == "needs_replan"))) then
                "blocked"
            else
                "queued"
            end;

        def finding_group_risk_bucket($items):
            ($items | map(.risk_bucket // "planned") | sort_by(risk_rank(.)) | first) // "planned";

        def finding_group_severity($items):
            ($items | map(.severity // "P4") | sort_by(severity_rank(.)) | first) // null;

        def build_finding_groups($raw_findings; $tasks):
            [
                $raw_findings[]
                | select(
                    (.link_task_id // null) == null
                    or (.admission_status // "active") == "watchlist"
                )
            ]
            | sort_by([.group_key, .finding_key])
            | group_by(.group_key)
            | map(
                . as $items
                | $items[0] as $rep
                | (
                    [
                        $items[]
                        | (.link_task_id // .related_task_id // null)
                        | select(. != null)
                    ] | unique
                ) as $related_ids
                | ([$related_ids[] | task_title_by_id(.; $tasks)] | unique) as $related_titles
                | ([$items[] | select((.file_ref // null) != null) | .file_ref] | unique) as $file_refs
                | ([$items[] | .target_ac[]?] | unique) as $target_acs
                | ([$items[] | .id] | unique) as $finding_ids
                | ([$items[] | .summary] | unique) as $sample_summaries
                | (finding_group_state($items)) as $group_state
                | {
                    id: $rep.group_key,
                    title: (
                        ($rep.surface_label // "Review backlog")
                        + (
                            if ($related_titles | length) > 0 then
                                " for " + ($related_titles | join(", "))
                            else
                                ""
                            end
                        )
                    ),
                    summary: (
                        (
                            if ($sample_summaries | length) > 0 then
                                $sample_summaries[0]
                            else
                                ($rep.summary // "Review backlog")
                            end
                        )
                        + " ["
                        + (($finding_ids | length) | tostring)
                        + " findings]"
                    ),
                    surface_key: $rep.surface_key,
                    surface_label: $rep.surface_label,
                    state: $group_state,
                    admission_status: (
                        if $group_state == "deferred" then
                            "watchlist"
                        else
                            "active"
                        end
                    ),
                    severity: finding_group_severity($items),
                    risk_bucket: finding_group_risk_bucket($items),
                    target_ac: $target_acs,
                    related_task_ids: $related_ids,
                    file_refs: $file_refs,
                    finding_ids: $finding_ids,
                    sample_summaries: ($sample_summaries[:3]),
                    finding_count: ($finding_ids | length),
                    first_seen_round: ($items | map(.first_seen_round // ($round | tonumber)) | min),
                    last_seen_round: ($items | map(.last_seen_round // ($round | tonumber)) | max)
                }
            )
            | sort_by([
                (
                    if .state == "blocked" then
                        0
                    elif .state == "queued" then
                        1
                    else
                        2
                    end
                ),
                -(.last_seen_round // 0),
                .id
            ]);

        .feedback = (.feedback // {execution: [], review: []})
        | .events = (.events // [])
        | .raw_findings = (.raw_findings // [])
        | .finding_groups = (.finding_groups // [])
        | ([.tasks[] | select(is_embedded_finding_task(.)) | raw_finding_from_task(.)]) as $migrated_findings
        | .tasks |= map(select(is_embedded_finding_task(.) | not))
        | reduce $migrated_findings[] as $raw_finding (
            .;
            (.raw_findings | map(.finding_key // "") | index($raw_finding.finding_key)) as $existing_idx
            | if $existing_idx != null then
                .raw_findings[$existing_idx] = merge_raw_finding(.raw_findings[$existing_idx]; $raw_finding)
              else
                .raw_findings += [$raw_finding]
              end
        )
        | reduce $findings[] as $finding (
            .;
            (raw_finding_from_finding($finding)) as $raw_finding
            | (.raw_findings | map(.finding_key // "") | index($raw_finding.finding_key)) as $existing_raw_idx
            | if $existing_raw_idx != null then
                .raw_findings[$existing_raw_idx] = merge_raw_finding(.raw_findings[$existing_raw_idx]; $raw_finding)
              else
                .raw_findings += [$raw_finding]
              end
            | (
                if ($finding.link_task_id // null) == null or ($finding.link_task_id // "") == "" then
                    null
                else
                    (.tasks | map(.id) | index($finding.link_task_id))
                end
              ) as $linked_idx
            | if $linked_idx != null then
                .tasks[$linked_idx] = annotate_linked_task(.tasks[$linked_idx]; $finding)
              else
                .
              end
            | .feedback.review += [feedback_entry($finding)]
            | .events += [event_entry($finding)]
        )
        | .finding_groups = build_finding_groups(.raw_findings; .tasks)
        | .raw_findings |= sort_by([-(.last_seen_round // 0), .finding_key])
        | .feedback.review |= sort_by([(.created_at // ""), (.summary // "")]) | .feedback.review |= reverse
        | .events |= sort_by([(.round // 0), (.id // "")]) | .events |= reverse
        | if (.manager | type) == "object" then
            .manager.last_reconciled_at = $created_at
          else
            .
          end
    ' "$matrix_file" > "$temp_file" && mv "$temp_file" "$matrix_file"
}

scenario_matrix_reconcile_manager_state() {
    local matrix_file="$1"
    local current_round="${2:-}"
    local frontier_reason="${3:-manager_reconcile}"

    if ! scenario_matrix_validate_file "$matrix_file"; then
        return 1
    fi

    local created_at temp_file
    created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    temp_file="${matrix_file}.tmp.$$"

    jq \
        --arg created_at "$created_at" \
        --arg current_round "$current_round" \
        --arg frontier_reason "$frontier_reason" '
        . as $root
        |
        def severity_rank($severity):
            (($severity // "P4") | ascii_downcase) as $s
            | if $s == "p0" then 0
              elif $s == "p1" then 1
              elif $s == "p2" then 2
              elif $s == "p3" then 3
              else 4
              end;

        def severity_score($severity):
            if severity_rank($severity) == 0 then 90
            elif severity_rank($severity) == 1 then 75
            elif severity_rank($severity) == 2 then 50
            elif severity_rank($severity) == 3 then 20
            else 0
            end;

        def risk_score($bucket):
            (($bucket // "planned") | ascii_downcase) as $b
            | if $b == "high" then 70
              elif $b == "medium" then 45
              elif $b == "planned" then 25
              elif $b == "low" then 10
              else 20
              end;

        def state_score($state):
            if $state == "needs_replan" then 105
            elif $state == "blocked" then 95
            elif $state == "in_progress" then 85
            elif $state == "ready" then 75
            elif $state == "pending" then 55
            else 0
            end;

        def is_open_task($task):
            ($task.state // "pending") != "done"
            and ($task.state // "pending") != "deferred";

        def is_watchlist($task):
            ($task.admission.status // "active") == "watchlist";

        def is_active_candidate($task):
            is_open_task($task) and (is_watchlist($task) | not);

        def is_open_finding_group($group):
            ($group.state // "queued") != "deferred";

        def is_watchlist_finding_group($group):
            ($group.admission_status // "active") == "watchlist"
            or (($group.state // "queued") == "deferred");

        def is_active_finding_group($group):
            is_open_finding_group($group) and (is_watchlist_finding_group($group) | not);

        def dependency_criticality($task):
            [
                $root.tasks[]
                | select(.id != ($task.id // ""))
                | select(((.depends_on // []) | index($task.id)) != null)
                | .id
            ] | length;

        def repair_wave_size($task):
            if (($task.repair_wave // "") | length) > 0 then
                [
                    $root.tasks[]
                    | select((.repair_wave // "") == $task.repair_wave)
                    | select(is_active_candidate(.))
                    | .id
                ] | length
            else
                0
            end;

        def frontier_task_score($task):
            (state_score($task.state // "pending"))
            + (risk_score($task.risk_bucket // "planned"))
            + (severity_score($task.severity // null))
            + ((dependency_criticality($task)) * 12)
            + (
                if repair_wave_size($task) > 1 then
                    (repair_wave_size($task) * 6)
                else
                    0
                end
            )
            + (
                if ($task.kind // "feature") == "defect" then
                    15
                elif ($task.kind // "feature") == "validation" then
                    10
                elif ($task.kind // "feature") == "investigation" then
                    5
                else
                    0
                end
            )
            + (
                if ($task.id // "") == ($root.manager.current_primary_task_id // "") then
                    30
                else
                    0
                end
            )
            + (
                if ($task.lane // "") == "mainline" then
                    15
                else
                    0
                end
            );

        def task_by_id($task_id):
            first($root.tasks[] | select(.id == $task_id));

        def current_primary_candidate:
            (.manager.current_primary_task_id // null) as $current_primary_task_id
            | if $current_primary_task_id == null then
                null
              else
                (task_by_id($current_primary_task_id) // null) as $candidate
                | if ($candidate | type) == "object" and is_active_candidate($candidate) then
                    $candidate
                  else
                    null
                  end
              end;

        def is_runnable_primary_candidate($task):
            is_active_candidate($task)
            and (($task.state // "pending") != "blocked")
            and (($task.state // "pending") != "needs_replan");

        def ranked_primary_candidate:
            (
                [
                    $root.tasks[]
                    | select(is_runnable_primary_candidate(.))
                    | {id: .id, score: frontier_task_score(.)}
                ]
            ) as $runnable
            | (
                if ($runnable | length) > 0 then
                    $runnable
                else
                    [
                        $root.tasks[]
                        | select(is_active_candidate(.))
                        | {id: .id, score: frontier_task_score(.)}
                    ]
                end
            ) as $candidate_pool
            | if ($candidate_pool | length) > 0 then
                ($candidate_pool | sort_by([.score, .id]) | last | .id)
              else
                null
              end;

        def related_to_primary($task; $primary):
            ($task.id // "") != ($primary.id // "")
            and (
                (($task.state // "pending") == "blocked")
                or (($task.state // "pending") == "needs_replan")
                or ((($primary.depends_on // []) | index($task.id)) != null)
                or (
                    (($primary.repair_wave // "") | length) > 0
                    and (($task.repair_wave // "") == ($primary.repair_wave // ""))
                )
            );

        def supporting_ids($primary_id):
            (task_by_id($primary_id) // null) as $primary
            | if ($primary | type) != "object" then
                []
              else
                [
                    $root.tasks[]
                    | select(is_active_candidate(.))
                    | select(related_to_primary(.; $primary))
                    | {id: .id, score: frontier_task_score(.)}
                ]
                | sort_by([-.score, .id])
                | .[:3]
                | map(.id)
              end;

        def residual_task_risk($task):
            if is_watchlist($task) then
                6
            elif ($task.state // "pending") == "done" or ($task.state // "pending") == "deferred" then
                0
            else
                ((risk_score($task.risk_bucket // "planned") / 2) | floor)
                + ((severity_score($task.severity // null) / 3) | floor)
                + (
                    if ($task.state // "pending") == "blocked" or ($task.state // "pending") == "needs_replan" then
                        22
                    elif ($task.state // "pending") == "in_progress" then
                        14
                    else
                        8
                    end
                )
            end;

        def residual_finding_group_risk($group):
            if is_watchlist_finding_group($group) then
                6
            elif ($group.state // "queued") == "blocked" or ($group.state // "queued") == "needs_replan" then
                ((risk_score($group.risk_bucket // "planned") / 2) | floor)
                + ((severity_score($group.severity // null) / 3) | floor)
                + 22
            else
                ((risk_score($group.risk_bucket // "planned") / 2) | floor)
                + ((severity_score($group.severity // null) / 3) | floor)
                + 8
            end;

        def convergence_guidance($status; $frontier_changed; $primary_id):
            if $status == "converged" then
                "No must-fix or high-risk active tasks remain. Reuse the current checkpoint for verification/closure and avoid opening new implementation scope."
            elif $status == "stabilizing" then
                "Residual risk is low and recent checkpoints are not producing new high-value findings. Hold the current checkpoint and focus on bounded verification."
            elif $frontier_changed then
                "The frontier changed. Refresh the contract from the new checkpoint and keep exactly one primary objective."
            elif $primary_id != null then
                "Continue within the current checkpoint. Do not widen scope unless the manager promotes a new frontier."
            else
                "Reconcile the frontier before starting new work."
            end;

        (.runtime.current_round // 0) as $existing_round
        | (
            if ($current_round | length) > 0 then
                ($current_round | tonumber)
            else
                $existing_round
            end
        ) as $round_num
        | (current_primary_candidate) as $current_primary_task
        | (
            if ($current_primary_task | type) == "object" then
                ($current_primary_task.id // null)
            else
                ranked_primary_candidate
            end
        ) as $primary_id
        | (supporting_ids($primary_id)) as $supporting_ids
        | .runtime.current_round = $round_num
        | .tasks |= map(
            .id as $task_id
            |
            if (.state // "pending") == "done" or (.state // "pending") == "deferred" then
                .
            else
                .lane = (
                    if ($primary_id != null and $task_id == $primary_id) then
                        "mainline"
                    elif is_watchlist(.) then
                        "queued"
                    elif ($supporting_ids | index($task_id)) != null then
                        "supporting"
                    elif (.state == "blocked" or .state == "needs_replan") then
                        "supporting"
                    else
                        "queued"
                    end
                )
            end
        )
        | if (.manager | type) == "object" then
            .manager.current_primary_task_id = $primary_id
            | .manager.last_reconciled_at = $created_at
          else
            .
          end
        | (
            (task_by_id($primary_id) // null) as $primary_task
            | ({
                primary_task_id: $primary_id,
                supporting_task_ids: $supporting_ids,
                open_active_ids: [
                    .tasks[]
                    | select(is_active_candidate(.))
                    | .id
                ],
                open_finding_group_ids: [
                    (.finding_groups // [])[]
                    | select(is_active_finding_group(.))
                    | .id
                ],
                blocked_ids: [
                    .tasks[]
                    | select(is_active_candidate(.))
                    | select(.state == "blocked" or .state == "needs_replan")
                    | .id
                ],
                blocked_finding_group_ids: [
                    (.finding_groups // [])[]
                    | select(is_active_finding_group(.))
                    | select(.state == "blocked" or .state == "needs_replan")
                    | .id
                ],
                repair_waves: [
                    .tasks[]
                    | select(is_active_candidate(.))
                    | select((.repair_wave // "") != "")
                    | .repair_wave
                ] | unique
            }) as $frontier_descriptor
            | ($frontier_descriptor | @json) as $frontier_signature
            | (.runtime.checkpoint // {}) as $checkpoint
            | (($checkpoint.frontier_signature // "") != $frontier_signature) as $frontier_changed
            | (
                if (($checkpoint.sequence // 0) == 0) then
                    1
                elif $frontier_changed then
                    (($checkpoint.sequence // 0) + 1)
                else
                    ($checkpoint.sequence // 0)
                end
            ) as $checkpoint_sequence
            | (
                ([.tasks[] | select(is_active_candidate(.))] | length)
                + ([.finding_groups[]? | select(is_active_finding_group(.))] | length)
              ) as $active_task_count
            | (
                ([.tasks[] | select(is_watchlist(.))] | length)
                + ([.finding_groups[]? | select(is_watchlist_finding_group(.))] | length)
              ) as $watchlist_count
            | (
                ([.tasks[]
                    | select(is_active_candidate(.))
                    | select(
                        (.state == "blocked")
                        or (.state == "needs_replan")
                        or ((.risk_bucket // "planned") == "high")
                        or (severity_rank(.severity // null) <= 1)
                      )
                  ] | length)
                + ([.finding_groups[]?
                    | select(is_active_finding_group(.))
                    | select(
                        (.state == "blocked")
                        or (.state == "needs_replan")
                        or ((.risk_bucket // "planned") == "high")
                        or (severity_rank(.severity // null) <= 1)
                      )
                  ] | length)
              ) as $must_fix_open_count
            | (
                ([.tasks[]
                    | select(is_active_candidate(.))
                    | select((.risk_bucket // "planned") == "high" or severity_rank(.severity // null) <= 1)
                  ] | length)
                + ([.finding_groups[]?
                    | select(is_active_finding_group(.))
                    | select((.risk_bucket // "planned") == "high" or severity_rank(.severity // null) <= 1)
                  ] | length)
              ) as $high_risk_open_count
            | (
                (([.tasks[] | residual_task_risk(.)] | add) // 0)
                + (([.finding_groups[]? | residual_finding_group_risk(.)] | add) // 0)
              ) as $residual_risk_score
            | (
                [
                    .events[]
                    | select((.type // "") == "review_finding")
                    | select(((.round // 0) >= ($round_num - 1)))
                    | select(severity_rank(.severity // null) <= 2)
                    | (.finding_key // .id)
                ] | unique | length
            ) as $recent_high_value_novelty_count
            | (
                if $must_fix_open_count == 0 and $high_risk_open_count == 0 and $active_task_count == 0 then
                    "converged"
                elif $must_fix_open_count == 0 and $high_risk_open_count == 0 and $recent_high_value_novelty_count == 0 and $residual_risk_score <= 25 then
                    "stabilizing"
                else
                    "continue"
                end
            ) as $convergence_status
            | .runtime.checkpoint = {
                sequence: $checkpoint_sequence,
                current_id: ("checkpoint-" + ($checkpoint_sequence | tostring)),
                frontier_signature: $frontier_signature,
                frontier_changed: $frontier_changed,
                primary_task_id: $primary_id,
                supporting_task_ids: $supporting_ids,
                frontier_reason: $frontier_reason,
                updated_at: $created_at
            }
            | .runtime.convergence = {
                status: $convergence_status,
                next_action: (
                    if $convergence_status == "converged" then
                        "prepare_closure"
                    elif $convergence_status == "stabilizing" then
                        "hold_checkpoint"
                    elif $frontier_changed then
                        "advance_checkpoint"
                    else
                        "hold_checkpoint"
                    end
                ),
                guidance: convergence_guidance($convergence_status; $frontier_changed; $primary_id),
                residual_risk_score: $residual_risk_score,
                must_fix_open_count: $must_fix_open_count,
                high_risk_open_count: $high_risk_open_count,
                active_task_count: $active_task_count,
                watchlist_count: $watchlist_count,
                recent_high_value_novelty_count: $recent_high_value_novelty_count,
                updated_at: $created_at
            }
        )
    ' "$matrix_file" > "$temp_file" && mv "$temp_file" "$matrix_file"
}

scenario_matrix_current_checkpoint_markdown() {
    local matrix_file="$1"

    if ! scenario_matrix_validate_file "$matrix_file"; then
        return 1
    fi

    jq -r '
        . as $root
        |
        def clean_text:
            tostring
            | gsub("\\|"; "/")
            | gsub("\\r?\\n"; " ");

        def primary_summary:
            if ($root.runtime.checkpoint.primary_task_id // null) != null then
                (
                    first($root.tasks[] | select(.id == $root.runtime.checkpoint.primary_task_id)) // null
                ) as $task
                | if ($task | type) == "object" then
                    ($task.id // "unknown") + " - " + (($task.title // "Untitled task") | clean_text)
                  else
                    ($root.runtime.checkpoint.primary_task_id // "unknown")
                  end
            else
                "none"
            end;

        "## Manager Checkpoint\n\n"
        + "- Checkpoint: `"
        + ((.runtime.checkpoint.current_id // "checkpoint-0") | clean_text)
        + "`"
        + (if (.runtime.checkpoint.frontier_changed // false) then " (frontier changed)" else " (frontier stable)" end)
        + "\n- Primary Objective: "
        + (primary_summary | clean_text)
        + "\n- Supporting Window: "
        + (
            if ((.runtime.checkpoint.supporting_task_ids // []) | length) > 0 then
                ((.runtime.checkpoint.supporting_task_ids // []) | join(", "))
            else
                "none"
            end
        )
        + "\n- Residual Risk: `"
        + ((.runtime.convergence.residual_risk_score // 0) | tostring)
        + "`"
        + " (must-fix="
        + ((.runtime.convergence.must_fix_open_count // 0) | tostring)
        + ", high-risk="
        + ((.runtime.convergence.high_risk_open_count // 0) | tostring)
        + ", novelty="
        + ((.runtime.convergence.recent_high_value_novelty_count // 0) | tostring)
        + ")"
        + (
            if ((.runtime.review_coverage // null) | type) == "object"
               and (
                    (((.runtime.review_coverage.touched_failure_surfaces // []) | length) > 0)
                    or (((.runtime.review_coverage.likely_sibling_risks // []) | length) > 0)
                    or (((.runtime.review_coverage.coverage_ledger // []) | length) > 0)
               ) then
                "\n- Review Coverage Snapshot: surfaces="
                + (((.runtime.review_coverage.summary.surface_count // 0) | tostring))
                + ", sibling-risks="
                + (((.runtime.review_coverage.summary.sibling_risk_count // 0) | tostring))
                + ", partial-or-unclear="
                + (((.runtime.review_coverage.summary.partial_or_unclear_count // 0) | tostring))
              else
                ""
              end
        )
        + "\n- Convergence Status: `"
        + ((.runtime.convergence.status // "continue") | clean_text)
        + "`"
        + "\n- Guidance: "
        + ((.runtime.convergence.guidance // "Reconcile the manager frontier before starting work.") | clean_text)
    ' "$matrix_file"
}

scenario_matrix_current_mainline_summary() {
    local matrix_file="$1"

    if ! scenario_matrix_validate_file "$matrix_file"; then
        echo "No valid scenario matrix is available."
        return 1
    fi

    jq -r '
        . as $root
        |
        def active_task:
            if ($root.manager.current_primary_task_id // null) != null then
                (
                    first(
                        $root.tasks[]
                        | select(.id == $root.manager.current_primary_task_id)
                        | select(.state != "done" and .state != "deferred")
                    ) // null
                )
            else
                (
                    first(
                        .tasks[]
                        | select(.lane == "mainline")
                        | select(.state != "done" and .state != "deferred")
                    ) // null
                )
            end;

        if (active_task | type) == "object" then
            (active_task.id // "unknown")
            + " - "
            + (active_task.title // "Untitled task")
            + " [state="
            + (active_task.state // "unknown")
            + ", routing="
            + (active_task.routing // "unknown")
            + "]"
        elif (.tasks | length) > 0 then
            "No active mainline task is recorded; reconcile the matrix before editing the contract."
        else
            "No tasks are currently recorded in the scenario matrix."
        end
    ' "$matrix_file"
}

scenario_matrix_has_projectable_tasks() {
    local matrix_file="$1"

    if ! scenario_matrix_validate_file "$matrix_file"; then
        return 1
    fi

    jq -e '
        (.runtime.mode // "implementation") == "implementation"
        and (.tasks | length) > 0
    ' "$matrix_file" >/dev/null 2>&1
}

scenario_matrix_monitor_snapshot() {
    local matrix_file="$1"
    local matrix_required="${2:-false}"

    if [[ ! -f "$matrix_file" ]]; then
        if [[ "$matrix_required" == "true" ]]; then
            echo "missing|0|Scenario matrix file is missing.|idle|none|n/a|unknown|n/a|none"
        else
            echo "legacy|0|Legacy loop without scenario matrix.|idle|none|n/a|legacy|n/a|none"
        fi
        return 0
    fi

    if ! scenario_matrix_validate_file "$matrix_file"; then
        echo "invalid|0|Scenario matrix file is invalid.|idle|none|n/a|unknown|n/a|none"
        return 0
    fi

    jq -r '
        . as $root
        |
        def primary_task:
            if ($root.manager.current_primary_task_id // null) != null then
                (
                    first(
                        $root.tasks[]
                        | select(.id == $root.manager.current_primary_task_id)
                        | select(.state != "done" and .state != "deferred")
                    ) // null
                )
            else
                (
                    first(
                        $root.tasks[]
                        | select(.lane == "mainline")
                        | select(.state != "done" and .state != "deferred")
                    ) // null
                )
            end;

        def clean_text:
            tostring
            | gsub("\\|"; "/")
            | gsub("\\r?\\n"; " ");

        def wave_label($task):
            if ($task | type) == "object" then
                if (($task.repair_wave // "") | length) > 0 then
                    $task.repair_wave
                elif (($task.cluster_id // "") | length) > 0 then
                    $task.cluster_id
                else
                    "none"
                end
            else
                "none"
            end;

        [
            (
                if (.plan.task_breakdown_status // "missing") == "not_applicable" then
                    "not_applicable"
                else
                    "ready"
                end
            ),
            ((.tasks | length) | tostring),
            (
                if (primary_task | type) == "object" then
                    (primary_task.id // "unknown")
                    + " - "
                    + (primary_task.title // "Untitled task")
                    + " [state="
                    + (primary_task.state // "unknown")
                    + ", routing="
                    + (primary_task.routing // "unknown")
                    + "]"
                elif (.tasks | length) > 0 then
                    "No active mainline task is recorded."
                else
                    "No tasks are currently recorded."
                end
                | clean_text
            ),
            ((.oversight.status // "idle") | clean_text),
            (
                (
                    .oversight.last_action
                    // (.oversight.intervention.action // "none")
                    // "none"
                )
                | clean_text
            ),
            ((.runtime.checkpoint.current_id // "n/a") | clean_text),
            ((.runtime.convergence.status // "unknown") | clean_text),
            ((.runtime.convergence.next_action // "n/a") | clean_text),
            (wave_label(primary_task) | clean_text)
        ] | join("|")
    ' "$matrix_file"
}

scenario_matrix_render_goal_tracker_active_section() {
    local matrix_file="$1"
    local variant="${2:-full}"

    jq -r --arg variant "$variant" '
        def md_text:
            tostring
            | gsub("\\|"; "\\\\|")
            | gsub("\\r?\\n"; " ");

        def owner:
            if ((.owner // "") | length) > 0 then
                .owner
            elif (.routing // "") == "analyze" then
                "codex"
            else
                "claude"
            end;

        def notes_full:
            [
                ("id=" + (.id // "unknown")),
                (if ((.depends_on // []) | length) > 0 then
                    "depends_on=" + ((.depends_on // []) | join(", "))
                 else
                    empty
                 end)
            ] | join("; ");

        def notes_compact:
            [
                ("id=" + (.id // "unknown")),
                ("routing=" + (.routing // "unknown")),
                (if ((.depends_on // []) | length) > 0 then
                    "depends_on=" + ((.depends_on // []) | join(", "))
                 else
                    empty
                 end)
            ] | join("; ");

        def target_acs:
            ((.target_ac // []) | map(md_text) | join(", "));

        def active_rows_full:
            [
                .tasks[]
                | select(.lane == "mainline")
                | select(.state != "done" and .state != "deferred")
                | "| [mainline] "
                  + ((.title // "Untitled task") | md_text)
                  + " | "
                  + target_acs
                  + " | "
                  + (.state // "pending")
                  + " | "
                  + (.routing // "coding")
                  + " | "
                  + owner
                  + " | "
                  + notes_full
                  + " |"
            ];

        def active_rows_compact:
            [
                .tasks[]
                | select(.lane == "mainline")
                | select(.state != "done" and .state != "deferred")
                | "| [mainline] "
                  + ((.title // "Untitled task") | md_text)
                  + " | "
                  + target_acs
                  + " | "
                  + (.state // "pending")
                  + " | "
                  + notes_compact
                  + " |"
            ];

        "#### Active Tasks\n"
        + (
            if $variant == "compact" then
                "| Task | Target AC | Status | Notes |\n"
                + "|------|-----------|--------|-------|\n"
                + (
                    if (active_rows_compact | length) > 0 then
                        (active_rows_compact | join("\n"))
                    else
                        "| [matrix] No active mainline task recorded | - | pending | Reconcile scenario-matrix.json before editing the contract. |"
                    end
                )
            else
                "| Task | Target AC | Status | Tag | Owner | Notes |\n"
                + "|------|-----------|--------|-----|-------|-------|\n"
                + (
                    if (active_rows_full | length) > 0 then
                        (active_rows_full | join("\n"))
                    else
                        "| [matrix] No active mainline task recorded | - | pending | coding | claude | Reconcile scenario-matrix.json before editing the contract. |"
                    end
                )
            end
        )
    ' "$matrix_file"
}

scenario_matrix_render_goal_tracker_blocking_section() {
    local matrix_file="$1"

    jq -r '
        def md_text:
            tostring
            | gsub("\\|"; "\\\\|")
            | gsub("\\r?\\n"; " ");

        def blocking_rows:
            [
                .tasks[]
                | select(.lane != "mainline")
                | select(.state == "blocked" or .state == "needs_replan")
                | "| "
                  + ((.title // "Untitled task") | md_text)
                  + " ["
                  + (.id // "unknown")
                  + "] | "
                  + ((.runtime.current_round // 0) | tostring)
                  + " | "
                  + ((.target_ac // []) | map(md_text) | join(", "))
                  + " | "
                  + (
                        if ((.depends_on // []) | length) > 0 then
                            "Repair or confirm dependency: "
                            + ((.depends_on // []) | join(", "))
                        else
                            "Replan the supporting task before promoting it."
                        end
                    )
                  + " |"
            ];

        def group_rows:
            [
                (.finding_groups // [])[]
                | select(.state == "blocked")
                | "| "
                  + ((.title // "Review backlog") | md_text)
                  + " | "
                  + ((.last_seen_round // .first_seen_round // .runtime.current_round // 0) | tostring)
                  + " | "
                  + ((.target_ac // []) | map(md_text) | join(", "))
                  + " | "
                  + (
                        "Resolve the grouped review backlog before promoting more follow-up work. "
                        + ((.summary // "") | md_text)
                    )
                  + " |"
            ];

        "### Blocking Side Issues\n"
        + "| Issue | Discovered Round | Blocking AC | Resolution Path |\n"
        + "|-------|-----------------|-------------|-----------------|\n"
        + (
            if ((blocking_rows + group_rows) | length) > 0 then
                ((blocking_rows + group_rows) | join("\n"))
            else
                ""
            end
        )
    ' "$matrix_file"
}

scenario_matrix_render_goal_tracker_queued_section() {
    local matrix_file="$1"

    jq -r '
        def md_text:
            tostring
            | gsub("\\|"; "\\\\|")
            | gsub("\\r?\\n"; " ");

        def queued_rows:
            [
                .tasks[]
                | select(.lane != "mainline")
                | select(.state != "done" and .state != "deferred")
                | select(.state != "blocked" and .state != "needs_replan")
                | "| "
                  + ((.title // "Untitled task") | md_text)
                  + " ["
                  + (.id // "unknown")
                  + "] | "
                  + ((.runtime.current_round // 0) | tostring)
                  + " | "
                  + (
                        if (.state // "pending") == "in_progress" then
                            "Supporting work is active but does not replace the current mainline."
                        else
                            "Supporting work is queued behind the current single-mainline objective."
                        end
                    )
                  + " | "
                  + (
                        if ((.depends_on // []) | length) > 0 then
                            "After dependency completion: "
                            + ((.depends_on // []) | join(", "))
                        else
                            "When the next round contract promotes it."
                        end
                    )
                  + " |"
            ];

        def group_rows:
            [
                (.finding_groups // [])[]
                | select(.state == "queued")
                | "| "
                  + ((.title // "Review backlog") | md_text)
                  + " | "
                  + ((.last_seen_round // .first_seen_round // .runtime.current_round // 0) | tostring)
                  + " | "
                  + ("Grouped review backlog remains out of scope until the manager promotes it. " + ((.summary // "") | md_text))
                  + " | "
                  + (
                        if ((.related_task_ids // []) | length) > 0 then
                            "When related task context changes: "
                            + ((.related_task_ids // []) | join(", "))
                        else
                            "When the manager promotes this backlog into active repair work."
                        end
                    )
                  + " |"
            ];

        "### Queued Side Issues\n"
        + "| Issue | Discovered Round | Why Not Blocking | Revisit Trigger |\n"
        + "|-------|-----------------|------------------|-----------------|\n"
        + (
            if ((queued_rows + group_rows) | length) > 0 then
                ((queued_rows + group_rows) | join("\n"))
            else
                ""
            end
        )
    ' "$matrix_file"
}

scenario_matrix_render_goal_tracker_completed_section() {
    local matrix_file="$1"

    jq -r '
        def md_text:
            tostring
            | gsub("\\|"; "\\\\|")
            | gsub("\\r?\\n"; " ");

        def completed_rows:
            [
                .tasks[]
                | select(.state == "done")
                | "| "
                  + ((.target_ac // []) | map(md_text) | join(", "))
                  + " | "
                  + ((.title // "Untitled task") | md_text)
                  + " ["
                  + (.id // "unknown")
                  + "] | "
                  + ((.health.last_progress_round // .runtime.current_round // 0) | tostring)
                  + " | "
                  + ((.health.last_progress_round // .runtime.current_round // 0) | tostring)
                  + " | "
                  + "scenario-matrix.json:"
                  + (.id // "unknown")
                  + " |"
            ];

        "### Completed and Verified\n"
        + "| AC | Task | Completed Round | Verified Round | Evidence |\n"
        + "|----|------|-----------------|----------------|----------|\n"
        + (
            if (completed_rows | length) > 0 then
                (completed_rows | join("\n"))
            else
                ""
            end
        )
    ' "$matrix_file"
}

scenario_matrix_render_goal_tracker_deferred_section() {
    local matrix_file="$1"

    jq -r '
        def md_text:
            tostring
            | gsub("\\|"; "\\\\|")
            | gsub("\\r?\\n"; " ");

        def deferred_rows:
            [
                .tasks[]
                | select(.state == "deferred" or ((.admission.status // "") == "watchlist"))
                | "| "
                  + ((.title // "Untitled task") | md_text)
                  + " ["
                  + (.id // "unknown")
                  + "] | "
                  + ((.target_ac // []) | map(md_text) | join(", "))
                  + " | "
                  + ((.metadata.deferred_since_round // .metadata.source_round // .runtime.current_round // 0) | tostring)
                  + " | "
                  + ((.admission.reason // "Deferred until the manager promotes it.") | md_text)
                  + " | "
                  + (
                        if ((.repair_wave // "") | length) > 0 then
                            "When repair wave " + (.repair_wave | md_text) + " is promoted."
                        elif ((.depends_on // []) | length) > 0 then
                            "When " + ((.depends_on // []) | join(", ")) + " changes or is promoted."
                        else
                            "When the manager promotes it into the active frontier."
                        end
                    )
                  + " |"
            ];

        def group_rows:
            [
                (.finding_groups // [])[]
                | select(.state == "deferred")
                | "| "
                  + ((.title // "Review backlog") | md_text)
                  + " | "
                  + ((.target_ac // []) | map(md_text) | join(", "))
                  + " | "
                  + ((.first_seen_round // .last_seen_round // .runtime.current_round // 0) | tostring)
                  + " | "
                  + ("Deferred grouped review backlog. " + ((.summary // "") | md_text))
                  + " | "
                  + "When the manager promotes this backlog into active repair work."
                  + " |"
            ];

        "### Explicitly Deferred\n"
        + "| Task | Original AC | Deferred Since | Justification | When to Reconsider |\n"
        + "|------|-------------|----------------|---------------|-------------------|\n"
        + (
            if ((deferred_rows + group_rows) | length) > 0 then
                ((deferred_rows + group_rows) | join("\n"))
            else
                ""
            end
        )
    ' "$matrix_file"
}

scenario_matrix_replace_goal_tracker_section() {
    local tracker_file="$1"
    local start_pattern="$2"
    local end_pattern="$3"
    local replacement_file="$4"
    local temp_file="${tracker_file}.tmp.$$"

    if ! awk \
        -v start_pattern="$start_pattern" \
        -v end_pattern="$end_pattern" \
        -v replacement_file="$replacement_file" '
        BEGIN {
            in_section = 0
            replaced = 0
        }
        {
            if (!in_section && $0 ~ start_pattern) {
                while ((getline line < replacement_file) > 0) {
                    print line
                }
                close(replacement_file)
                in_section = 1
                replaced = 1
                next
            }
            if (in_section) {
                if (end_pattern != "" && $0 ~ end_pattern) {
                    in_section = 0
                    print
                }
                next
            }
            print
        }
        END {
            if (!replaced) {
                exit 1
            }
            if (in_section && end_pattern != "") {
                exit 1
            }
        }
    ' "$tracker_file" > "$temp_file"; then
        rm -f "$temp_file"
        return 1
    fi

    mv "$temp_file" "$tracker_file"
}

scenario_matrix_sync_goal_tracker() {
    local matrix_file="$1"
    local tracker_file="$2"

    if [[ ! -f "$tracker_file" ]]; then
        return 0
    fi

    if ! scenario_matrix_has_projectable_tasks "$matrix_file"; then
        return 0
    fi

    if ! grep -q '^#### Active Tasks$' "$tracker_file" || \
       ! grep -q '^### Blocking Side Issues$' "$tracker_file" || \
       ! grep -q '^### Queued Side Issues$' "$tracker_file"; then
        return 0
    fi

    local active_variant="compact"
    if grep -q '^| Task | Target AC | Status | Tag | Owner | Notes |$' "$tracker_file"; then
        active_variant="full"
    fi
    local has_completed_section="false"
    local has_deferred_section="false"
    if grep -q '^### Completed and Verified$' "$tracker_file"; then
        has_completed_section="true"
    fi
    if grep -q '^### Explicitly Deferred$' "$tracker_file"; then
        has_deferred_section="true"
    fi

    local active_file="${tracker_file}.active.$$"
    local blocking_file="${tracker_file}.blocking.$$"
    local queued_file="${tracker_file}.queued.$$"
    local completed_file="${tracker_file}.completed.$$"
    local deferred_file="${tracker_file}.deferred.$$"

    scenario_matrix_render_goal_tracker_active_section "$matrix_file" "$active_variant" > "$active_file"
    scenario_matrix_render_goal_tracker_blocking_section "$matrix_file" > "$blocking_file"
    scenario_matrix_render_goal_tracker_queued_section "$matrix_file" > "$queued_file"
    scenario_matrix_render_goal_tracker_completed_section "$matrix_file" > "$completed_file"
    scenario_matrix_render_goal_tracker_deferred_section "$matrix_file" > "$deferred_file"

    scenario_matrix_replace_goal_tracker_section "$tracker_file" '^#### Active Tasks$' '^### Blocking Side Issues$' "$active_file" || {
        rm -f "$active_file" "$blocking_file" "$queued_file" "$completed_file" "$deferred_file"
        return 1
    }
    scenario_matrix_replace_goal_tracker_section "$tracker_file" '^### Blocking Side Issues$' '^### Queued Side Issues$' "$blocking_file" || {
        rm -f "$active_file" "$blocking_file" "$queued_file" "$completed_file" "$deferred_file"
        return 1
    }
    if [[ "$has_completed_section" == "true" ]]; then
        local queued_end_pattern='^### Completed and Verified$'
        scenario_matrix_replace_goal_tracker_section "$tracker_file" '^### Queued Side Issues$' "$queued_end_pattern" "$queued_file" || {
            rm -f "$active_file" "$blocking_file" "$queued_file" "$completed_file" "$deferred_file"
            return 1
        }
        if [[ "$has_deferred_section" == "true" ]]; then
            scenario_matrix_replace_goal_tracker_section "$tracker_file" '^### Completed and Verified$' '^### Explicitly Deferred$' "$completed_file" || {
                rm -f "$active_file" "$blocking_file" "$queued_file" "$completed_file" "$deferred_file"
                return 1
            }
            scenario_matrix_replace_goal_tracker_section "$tracker_file" '^### Explicitly Deferred$' '' "$deferred_file" || {
                rm -f "$active_file" "$blocking_file" "$queued_file" "$completed_file" "$deferred_file"
                return 1
            }
        else
            scenario_matrix_replace_goal_tracker_section "$tracker_file" '^### Completed and Verified$' '' "$completed_file" || {
                rm -f "$active_file" "$blocking_file" "$queued_file" "$completed_file" "$deferred_file"
                return 1
            }
        fi
    else
        local queued_end_pattern=''
        if [[ "$has_deferred_section" == "true" ]]; then
            queued_end_pattern='^### Explicitly Deferred$'
        fi
        scenario_matrix_replace_goal_tracker_section "$tracker_file" '^### Queued Side Issues$' "$queued_end_pattern" "$queued_file" || {
            rm -f "$active_file" "$blocking_file" "$queued_file" "$completed_file" "$deferred_file"
            return 1
        }
        if [[ "$has_deferred_section" == "true" ]]; then
            scenario_matrix_replace_goal_tracker_section "$tracker_file" '^### Explicitly Deferred$' '' "$deferred_file" || {
                rm -f "$active_file" "$blocking_file" "$queued_file" "$completed_file" "$deferred_file"
                return 1
            }
        fi
    fi

    rm -f "$active_file" "$blocking_file" "$queued_file" "$completed_file" "$deferred_file"
}

scenario_matrix_render_round_contract() {
    local matrix_file="$1"
    local round="$2"
    local mode="${3:-implementation}"

    jq -r --arg round "$round" --arg mode "$mode" '
        . as $root
        |
        def clean_text:
            tostring
            | gsub("\\|"; "/")
            | gsub("\\r?\\n"; " ");

        def active_task:
            if ($root.runtime.checkpoint.primary_task_id // null) != null then
                (
                    first(
                        $root.tasks[]
                        | select(.id == $root.runtime.checkpoint.primary_task_id)
                        | select(.state != "done" and .state != "deferred")
                    ) // null
                )
            else
                (
                    first(
                        $root.tasks[]
                        | select(.lane == "mainline")
                        | select(.state != "done" and .state != "deferred")
                    ) // null
                )
            end;

        def checkpoint_supporting_items:
            [
                ($root.runtime.checkpoint.supporting_task_ids // [])[]
                | . as $task_id
                | first($root.tasks[] | select(.id == $task_id))
                | ($task_id + ": " + ((.title // "Untitled task") | clean_text))
            ];

        def blocking_items:
            [
                $root.tasks[]
                | select(.lane != "mainline")
                | select(.state == "blocked" or .state == "needs_replan")
                | ((.id // "task") + ": " + ((.title // "Untitled task") | clean_text))
            ]
            + [
                ($root.finding_groups // [])[]
                | select(.state == "blocked")
                | ("issue:" + (.id // "review-backlog") + ": " + ((.title // "Review backlog") | clean_text))
            ];

        def queued_items:
            [
                $root.tasks[]
                | .id as $task_id
                | select(.lane != "mainline")
                | select(.state != "done" and .state != "deferred")
                | select(.state != "blocked" and .state != "needs_replan")
                | select((($root.runtime.checkpoint.supporting_task_ids // []) | index($task_id)) == null)
                | ((.id // "task") + ": " + ((.title // "Untitled task") | clean_text))
            ]
            + [
                ($root.finding_groups // [])[]
                | select(.state == "queued")
                | ("issue:" + (.id // "review-backlog") + ": " + ((.title // "Review backlog") | clean_text))
            ];

        "# Round " + $round + " Contract\n\n"
        + "- Mainline Objective: "
        + (
            if (active_task | type) == "object" then
                (active_task.id // "task")
                + ": "
                + ((active_task.title // "Untitled task") | clean_text)
            else
                "Reconcile scenario-matrix.json and recover a single mainline objective."
            end
        )
        + "\n- Target ACs: "
        + (
            if (active_task | type) == "object" then
                ((active_task.target_ac // []) | join(", "))
            else
                "-"
            end
        )
        + "\n- Checkpoint: "
        + (($root.runtime.checkpoint.current_id // "checkpoint-0") | clean_text)
        + (
            if ($root.runtime.checkpoint.frontier_changed // false) then
                " (frontier changed)"
            else
                " (frontier stable)"
            end
        )
        + "\n- Supporting Window In Scope: "
        + (
            if (checkpoint_supporting_items | length) > 0 then
                (checkpoint_supporting_items | join("; "))
            else
                "none"
            end
        )
        + "\n- Blocking Side Issues In Scope: "
        + (
            if (blocking_items | length) > 0 then
                (blocking_items | join("; "))
            else
                "none"
            end
        )
        + "\n- Queued Side Issues Out of Scope: "
        + (
            if (queued_items | length) > 0 then
                (queued_items | join("; "))
            else
                "none"
            end
        )
        + "\n- Residual Risk: "
        + (
            "score="
            + (($root.runtime.convergence.residual_risk_score // 0) | tostring)
            + ", must-fix="
            + (($root.runtime.convergence.must_fix_open_count // 0) | tostring)
            + ", high-risk="
            + (($root.runtime.convergence.high_risk_open_count // 0) | tostring)
            + ", novelty="
            + (($root.runtime.convergence.recent_high_value_novelty_count // 0) | tostring)
        )
        + "\n- Convergence Status: "
        + (($root.runtime.convergence.status // "continue") | clean_text)
        + "\n- Success Criteria: "
        + (
            if $mode == "review" then
                "Resolve the review-blocking work while keeping the scenario matrix and goal tracker aligned with the same single mainline objective."
            elif $mode == "recovery" then
                "Recover mainline progress without widening scope beyond the current scenario matrix frontier."
            else
                "Advance the current mainline objective without widening scope beyond the scenario matrix frontier."
            end
        )
        + "\n- Checkpoint Guidance: "
        + (($root.runtime.convergence.guidance // "Reconcile the scenario matrix before widening scope.") | clean_text)
    ' "$matrix_file"
}

scenario_matrix_write_round_contract_scaffold() {
    local matrix_file="$1"
    local contract_file="$2"
    local round="$3"
    local mode="${4:-implementation}"
    local force_write="${5:-false}"

    if ! scenario_matrix_has_projectable_tasks "$matrix_file"; then
        return 0
    fi

    if [[ -f "$contract_file" && "$force_write" != "true" ]]; then
        return 0
    fi

    local temp_file="${contract_file}.tmp.$$"
    scenario_matrix_render_round_contract "$matrix_file" "$round" "$mode" > "$temp_file"
    mv "$temp_file" "$contract_file"
}

scenario_matrix_current_oversight_markdown() {
    local matrix_file="$1"

    if ! scenario_matrix_validate_file "$matrix_file"; then
        return 1
    fi

    jq -r '
        (.oversight.intervention // null) as $intervention
        | if (.oversight.status // "idle") == "active" and ($intervention | type) == "object" then
            "## Oversight Intervention\n\n"
            + "- Action: `" + ($intervention.action // "unknown") + "`\n"
            + (if ($intervention.target_task_id // "") != "" then
                "- Target Task: `" + $intervention.target_task_id + "`\n"
              else
                ""
              end)
            + "- Reason: " + ($intervention.reason // "Repeated failures require a narrower recovery path.") + "\n"
            + "- Guidance: " + ($intervention.message // "Stay on the current task and try a different method.")
          else
            empty
          end
    ' "$matrix_file"
}

scenario_matrix_current_review_coverage_markdown() {
    local matrix_file="$1"

    if ! scenario_matrix_validate_file "$matrix_file"; then
        return 1
    fi

    jq -r '
        (.runtime.review_coverage // null) as $coverage
        | if ($coverage | type) == "object"
             and (
                (($coverage.touched_failure_surfaces // []) | length) > 0
                or (($coverage.likely_sibling_risks // []) | length) > 0
                or (($coverage.coverage_ledger // []) | length) > 0
             ) then
            "## Recent Review Coverage\n\n"
            + "- Source: `round "
            + ((($coverage.source_round // 0) | tostring))
            + " / "
            + (($coverage.source_phase // "implementation"))
            + "`\n"
            + "- Touched Failure Surfaces: "
            + (
                if (($coverage.touched_failure_surfaces // []) | length) > 0 then
                    (
                        ($coverage.touched_failure_surfaces // [])
                        | map(
                            (.surface // "unknown")
                            + (
                                if (.confidence // null) != null and (.confidence // "") != "" then
                                    " [confidence=" + (.confidence // "") + "]"
                                else
                                    ""
                                end
                            )
                            + (
                                if (.reason // "") != "" then
                                    ": " + (.reason // "")
                                else
                                    ""
                                end
                            )
                        )
                        | .[:4]
                        | join("; ")
                    )
                else
                    "none captured"
                end
            )
            + "\n- Likely Sibling Risks: "
            + (
                if (($coverage.likely_sibling_risks // []) | length) > 0 then
                    (
                        ($coverage.likely_sibling_risks // [])
                        | map(
                            (.summary // "unknown")
                            + (
                                if (.expansion_axis // null) != null and (.expansion_axis // "") != "" then
                                    " [axis=" + (.expansion_axis // "") + "]"
                                else
                                    ""
                                end
                            )
                            + (
                                if (.confidence // null) != null and (.confidence // "") != "" then
                                    " [confidence=" + (.confidence // "") + "]"
                                else
                                    ""
                                end
                            )
                        )
                        | .[:4]
                        | join("; ")
                    )
                else
                    "none captured"
                end
            )
            + (
                if (($coverage.coverage_ledger // []) | length) > 0 then
                    "\n\n| Surface | Status | Notes |\n|---------|--------|-------|\n"
                    + (
                        ($coverage.coverage_ledger // [])
                        | map(
                            "| "
                            + (.surface // "unknown")
                            + " | "
                            + (.status // "unclear")
                            + " | "
                            + ((.notes // "") | gsub("\\|"; "/") | gsub("\\r?\\n"; " "))
                            + " |"
                        )
                        | join("\n")
                    )
                else
                    ""
                end
            )
          else
            empty
          end
    ' "$matrix_file"
}

scenario_matrix_apply_implementation_review() {
    local matrix_file="$1"
    local next_round="$2"
    local verdict="$3"
    local review_content="$4"

    if ! scenario_matrix_validate_file "$matrix_file"; then
        return 1
    fi

    local verdict_lower dependency_hint created_at event_id temp_file review_content_lower review_coverage_json
    verdict_lower=$(printf '%s' "$verdict" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    dependency_hint=$(scenario_matrix_dependency_hint_from_review "$review_content")
    review_content_lower=$(printf '%s' "$review_content" | tr '[:upper:]' '[:lower:]')
    review_coverage_json=$(scenario_matrix_extract_review_coverage_json "$review_content")
    created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    event_id="evt-impl-${next_round}-$(date +%s)"
    temp_file="${matrix_file}.tmp.$$"

    jq \
        --arg created_at "$created_at" \
        --arg event_id "$event_id" \
        --arg verdict "$verdict_lower" \
        --arg round "$next_round" \
        --arg dependency_hint "$dependency_hint" \
        --arg review_content_lower "$review_content_lower" \
        --argjson review_coverage "$review_coverage_json" '
        def active_mainline_id:
            first(
                .tasks[]
                | select(.lane == "mainline")
                | select(.state != "done" and .state != "deferred")
                | .id
            );

        def should_split:
            $review_content_lower | test("split|smaller|decompose|narrow");

        def should_reclassify:
            $review_content_lower | test("queued|not blocking|non-blocking|follow-up|defer");

        def dependency_state($tasks; $id):
            first($tasks[] | select(.id == $id) | .state) // "missing";

        def reopened_dependency_state($tasks; $task):
            if (($task.depends_on // []) | any(.[]; dependency_state($tasks; .) == "needs_replan")) then
                "needs_replan"
            elif (($task.depends_on // []) | any(.[]; dependency_state($tasks; .) == "blocked")) then
                "blocked"
            elif (($task.depends_on // []) | length) == 0 then
                "ready"
            elif (($task.depends_on // []) | all(.[]; dependency_state($tasks; .) == "done")) then
                "ready"
            else
                "pending"
            end;

        (active_mainline_id) as $active_id
        | .runtime.current_round = ($round | tonumber)
        | .runtime.review_coverage = (
            $review_coverage
            + {
                source_phase: "implementation",
                source_round: ($round | tonumber),
                updated_at: $created_at
            }
        )
        | .runtime.last_review = {
            phase: "implementation",
            verdict: $verdict,
            dependency_hint: ($dependency_hint == "true"),
            coverage_available: (
                (($review_coverage.touched_failure_surfaces // []) | length) > 0
                or (($review_coverage.likely_sibling_risks // []) | length) > 0
                or (($review_coverage.coverage_ledger // []) | length) > 0
            ),
            coverage_summary: ($review_coverage.summary // {}),
            updated_at: $created_at
        }
        | if (.manager | type) == "object" then
            .manager.last_reconciled_at = $created_at
            | .manager.current_primary_task_id = (
                if $active_id == null then
                    (.manager.current_primary_task_id // null)
                else
                    $active_id
                end
            )
          else
            .
          end
        | .events += [{
            id: $event_id,
            type: "implementation_review",
            round: ($round | tonumber),
            phase: "implementation",
            verdict: $verdict,
            dependency_hint: ($dependency_hint == "true"),
            created_at: $created_at
        }]
        | .tasks |= (
            map(
                if (.state == "done" or .state == "deferred") then
                    .
                elif .id == $active_id then
                    if $verdict == "advanced" then
                        .state = "in_progress"
                        | .health.stuck_score = 0
                        | .health.last_progress_round = ($round | tonumber)
                        | .strategy.repeated_failure_count = 0
                        | .strategy.method_switch_required = false
                    elif $verdict == "stalled" then
                        .state = (if .state == "ready" then "in_progress" else .state end)
                        | .health.stuck_score = ((.health.stuck_score // 0) + 1)
                        | .strategy.repeated_failure_count = ((.strategy.repeated_failure_count // 0) + 1)
                        | .strategy.method_switch_required = (((.strategy.repeated_failure_count // 0) + 1) >= 2)
                    elif $verdict == "regressed" then
                        .state = "needs_replan"
                        | .health.stuck_score = ((.health.stuck_score // 0) + 1)
                        | .strategy.repeated_failure_count = ((.strategy.repeated_failure_count // 0) + 1)
                        | .strategy.method_switch_required = (((.strategy.repeated_failure_count // 0) + 1) >= 2)
                    else
                        .
                    end
                elif $dependency_hint == "true"
                    and $active_id != null
                    and $verdict == "stalled"
                    and ((.depends_on // []) | index($active_id)) != null then
                    .state = "blocked"
                elif $dependency_hint == "true"
                    and $active_id != null
                    and $verdict == "regressed"
                    and ((.depends_on // []) | index($active_id)) != null then
                    .state = "needs_replan"
                else
                    .
                end
            ) as $updated_tasks
            | $updated_tasks
            | map(
                if $verdict == "advanced"
                    and $active_id != null
                    and ((.depends_on // []) | index($active_id)) != null
                    and (.state == "blocked" or .state == "needs_replan") then
                    .state = reopened_dependency_state($updated_tasks; .)
                else
                    .
                end
            )
        )
        | (first(.tasks[] | select(.id == $active_id)) // null) as $active_task
        | ($active_task.strategy.repeated_failure_count // 0) as $failure_count
        | ($active_task.health.stuck_score // 0) as $stuck_score
        | .oversight = (
            if $verdict == "advanced" then
                {
                    status: "idle",
                    last_action: "none",
                    updated_at: $created_at,
                    intervention: null,
                    history: (.oversight.history // [])
                }
            elif ($active_task | type) == "object" and ($failure_count >= 2 or $stuck_score >= 2) then
                (
                    if should_reclassify then
                        {
                            action: "reclassify",
                            reason: "Review feedback indicates that some findings should stay queued instead of replacing the current mainline objective.",
                            message: "Stay on the current mainline task and move non-blocking follow-up work back to queued status."
                        }
                    elif $dependency_hint == "true" then
                        {
                            action: "resequence",
                            reason: "An upstream dependency changed and invalidated downstream work.",
                            message: "Stay on the current mainline task, repair the upstream dependency first, and resequence dependent work afterward."
                        }
                    elif should_split then
                        {
                            action: "split",
                            reason: "Repeated failures suggest the current step is too broad.",
                            message: "Stay on the current mainline task, but split it into a smaller recovery step before changing more code."
                        }
                    elif $verdict == "regressed" then
                        {
                            action: "reframe",
                            reason: "Repeated regressions indicate the current method is not working.",
                            message: "Stay on the current mainline task and try a different method instead of repeating the same path."
                        }
                    else
                        {
                            action: "nudge",
                            reason: "Repeated stalled rounds indicate local thrashing without forward movement.",
                            message: "Stay on the current mainline task and try a narrower corrective step before expanding scope."
                        }
                    end
                ) as $intervention
                | {
                    status: "active",
                    last_action: $intervention.action,
                    updated_at: $created_at,
                    intervention: (
                        $intervention
                        + {
                            target_task_id: ($active_task.id // null),
                            generated_for_round: ($round | tonumber),
                            failure_count: $failure_count,
                            stuck_score: $stuck_score
                        }
                    ),
                    history: (
                        (.oversight.history // [])
                        + [
                            (
                                $intervention
                                + {
                                    target_task_id: ($active_task.id // null),
                                    generated_for_round: ($round | tonumber),
                                    failure_count: $failure_count,
                                    stuck_score: $stuck_score,
                                    created_at: $created_at
                                }
                            )
                        ]
                    )
                }
            else
                {
                    status: "idle",
                    last_action: (.oversight.last_action // "none"),
                    updated_at: $created_at,
                    intervention: null,
                    history: (.oversight.history // [])
                }
            end
        )
    ' "$matrix_file" > "$temp_file" && mv "$temp_file" "$matrix_file"
}

scenario_matrix_record_code_review_cycle() {
    local matrix_file="$1"
    local next_round="$2"
    local event_type="${3:-code_review_issues}"
    local implementation_review_content="${4:-}"

    if ! scenario_matrix_validate_file "$matrix_file"; then
        return 1
    fi

    local created_at event_id temp_file implementation_review_coverage
    created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    event_id="evt-review-${next_round}-$(date +%s)"
    temp_file="${matrix_file}.tmp.$$"
    implementation_review_coverage='{}'
    if [[ -n "$implementation_review_content" ]]; then
        implementation_review_coverage=$(scenario_matrix_extract_review_coverage_json "$implementation_review_content")
    fi

    jq \
        --arg created_at "$created_at" \
        --arg event_id "$event_id" \
        --arg event_type "$event_type" \
        --arg round "$next_round" \
        --argjson implementation_review_coverage "$implementation_review_coverage" '
        def coverage_has_entries($coverage):
            (
                (($coverage.touched_failure_surfaces // []) | length) > 0
                or (($coverage.likely_sibling_risks // []) | length) > 0
                or (($coverage.coverage_ledger // []) | length) > 0
            );
        .runtime.current_round = ($round | tonumber)
        | if coverage_has_entries($implementation_review_coverage) then
            .runtime.review_coverage = (
                $implementation_review_coverage
                + {
                    source_phase: "implementation",
                    source_round: ($round | tonumber),
                    updated_at: $created_at
                }
            )
          else
            .
          end
        | .runtime.last_review = {
            phase: "review",
            verdict: $event_type,
            dependency_hint: false,
            coverage_available: (
                if (.runtime.review_coverage // null) | type == "object" then
                    (
                        (((.runtime.review_coverage.touched_failure_surfaces // []) | length) > 0)
                        or (((.runtime.review_coverage.likely_sibling_risks // []) | length) > 0)
                        or (((.runtime.review_coverage.coverage_ledger // []) | length) > 0)
                    )
                else
                    false
                end
            ),
            coverage_summary: ((.runtime.review_coverage.summary // {})),
            updated_at: $created_at
        }
        | if (.manager | type) == "object" then
            .manager.last_reconciled_at = $created_at
          else
            .
          end
        | .events += [{
            id: $event_id,
            type: $event_type,
            round: ($round | tonumber),
            phase: "review",
            verdict: $event_type,
            dependency_hint: false,
            created_at: $created_at
        }]
    ' "$matrix_file" > "$temp_file" && mv "$temp_file" "$matrix_file"
}
