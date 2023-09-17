#!/usr/bin/env bash

# shellcheck disable=2034,2162,2155,2207

declare -gx BASH_REST_PROJECT_BASE_DIRECTORY="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
declare -i BASH_REST_PORT=3000
declare BASH_REST_RESPONSE_FIFO="bash_rest_response"
declare BASH_REST_RESPONSE_FIFO_PATH="${BASH_REST_PROJECT_BASE_DIRECTORY}/fifo/${BASH_REST_RESPONSE_FIFO}"
declare -a BASH_REST_MAPPED_ENDPOINTS

bash_rest_404_not_found() {
	cat <<EOF
	HTTP/1.1 404 NotFound

EOF
}

bash_rest_print_log() {
	local log_level="${1}"
	local log_message="${2}"
	local current_timestamp=$(date +"%Y-%m-%d %H:%M:%S.%3N")

	if [[ "${log_level}" == "INFO" ]]; then
		log_level="[${log_level}]      "
	elif [[ "${log_level}" == "ERROR" ]] || [[ "${log_level}" == "FATAL" ]] || [[ "${log_level}" == "DEBUG" ]]; then
		log_level="[${log_level}]     "
	fi

	echo "${current_timestamp}    ${log_level} $$    ---    ${log_message}"
}

get_annotation_endpoint() {
	local annotation="${1}"
	local endpoint

	endpoint=$(declare -f "${annotation}" | grep -oP "local bash_rest_endpoint=[\"\'a-zA-Z0-9{}:./_-]+$")
	# strip variable name, = and ""
	endpoint="${endpoint##*=}"
	endpoint="${endpoint%*\"}"
	endpoint="${endpoint#\"*}"

	echo "${endpoint}"
}

get_annotation_target_function() {
	local annotation="${1}"
	declare -f "${annotation}" | grep -oP "(?<=local bash_rest_target_annotation=)(?<=\")?(?<=\')?[a-zA-Z:./_-]+"
}

get_annotation_source_file() {
	local annotation="${1}"
	declare -f "${annotation}" | grep -oP "(?<=local bash_rest_function_source_file=)(?<=\")?(?<=\')?[a-zA-Z:./_-]+"

}

get_annotation_http_method() {
	local annotation="${1}"

	annotation="${annotation%%_*}"
	annotation="${annotation#*@}"
	echo "${annotation^^}"
}

get_request_path_variables() {
	local base_endpoint="${1}"
	local incoming_request_endpoint="${2}"
	local -n parsed_variables_array="${3}"
	# Associative arrays are sorted by hash, not by key or value
	# This is a problem, assistant array with keys at ordered indexes are used as a ref
	local -A substring_map
	local -a substring_map_ref
	local -a endpoint_segments
	local -i start=-1
	local -i end=-1

	for ((i = 0; i < "${#base_endpoint}"; i++)); do
		if [[ "${base_endpoint:$i:1}" == '{' ]] && [[ $start == -1 ]]; then
			start="${i}"
		fi

		if [[ "${base_endpoint:$i:1}" == '}' ]] && [[ $start != -1 ]]; then
			end="${i}"
		fi
		if [[ $start != -1 ]] && [[ $end != -1 ]]; then
			substring_map+=([$start]=$end)
			substring_map_ref+=("${start}")
			start=-1
			end=-1
		fi
	done

	# Isolate variables dynamically
	for i in "${substring_map_ref[@]}"; do
		# For each substring range (i.e. key value pair in associative array), parse
		# out parameter, including curly bracers but excluding '/'
		parameter="${base_endpoint:${i}:((${substring_map[${i}]} - $i + 1))}"
		# get abutting text, as substrings become useless if parameter arguments are not
		# the same length as {parameterVariableName} - I think...
		endpoint_segments+=($(grep -oP "[0-9a-zA-Z-/?=:]+(?=${parameter})" < <(echo "${base_endpoint}")))
		endpoint_segments+=($(grep -oP "(?<=${parameter})[0-9a-zA-Z-/?=:]+" < <(echo "${base_endpoint}")))
	done

	unique_endpoint_sections=($(printf "%s\n" "${endpoint_segments[@]}" | awk '!seen[$0]++'))

	# Isolate abutting non-variable portions of endpoint
	for ((i = 0; i < "${#unique_endpoint_sections[@]}"; i++)); do

		if [[ "${i}" -eq $(("${#unique_endpoint_sections[@]}" - 1)) ]]; then
			# Check for trailing variable
			parsed_variables_array+=($(grep -oP "(?<=${unique_endpoint_sections[${i}]})[0-9a-zA-Z-]+$" < <(echo "${incoming_request_endpoint}")))
		else
			# Check for sandwiched variable
			parsed_variables_array+=(
				$(grep -oP \
					"(?<=${unique_endpoint_sections[${i}]})[0-9a-zA-Z-]+(?=${unique_endpoint_sections[$((i + 1))]})" \
					< <(echo "${incoming_request_endpoint}"))
			)
		fi

	done

	# shellcheck disable=2207
	parsed_variables_array=($(printf "%s\n" "${parsed_variables_array[@]}" | awk '!seen[$0]++'))
}

get_controller_annotations() {
	local -n controller_annotations_array="${1}"
	mapfile -t controller_annotations_array < <(declare -F | cut -d " " -f 3 | grep -oP "^@(?:get|post|put|delete)[a-zA-Z:./_-]+_[0-9]+$")
}

strip_path_variable_names() {
	local endpoint="${1}"
	# shellcheck disable=2001
	echo "${endpoint}" | sed 's/{[^}]*}/{}/g'
}

populate_bash_rest_mapped_endpoints_array() {
	local endpoint="${1}"
	BASH_REST_MAPPED_ENDPOINTS+=("$(strip_path_variable_names "${endpoint}")")
}

get_endpoint_match() {
	incoming_endpoint_call="${1}"

	for endpoint in "${BASH_REST_MAPPED_ENDPOINTS[@]}"; do
		# Replace "{}" in the pattern with a regex to match any value
		# except for / ? and }
		regex_pattern="^${endpoint//\{\}/[^\}/?]+}$"
		# shellcheck disable=2154
		if [[ $incoming_endpoint_call =~ ^$regex_pattern$ ]]; then
			echo "${endpoint}"
		fi
	done
}

parse_controller_annotations() {
	local -n controller_endpoint_functions_map="${1}"
	shift
	local -a controller_annotations_array=("${@}")

	for annotation in "${controller_annotations_array[@]}"; do
		# get endpoint mapping
		endpoint=$(get_annotation_endpoint "${annotation}")
		# get function associated with endpoint
		target_function=$(get_annotation_target_function "${annotation}")
		http_method="$(get_annotation_http_method "${annotation}")"
		unique_mapping_identifier="${http_method} ${endpoint}"
		populate_bash_rest_mapped_endpoints_array "${unique_mapping_identifier}"
		controller_endpoint_functions_map+=(["${unique_mapping_identifier}"]="${target_function}")
	done
}

build_endpoint_handler_function() {
	local -n endpoint_function_map="${1}"
	local controller_switch_start="case \"\${bash_rest_endpoint_match}\" in "
	local controller_switch_statement=""
	# shellcheck disable=2016
	local controller_switch_end="*) bash_rest_404_response=\"\$(bash_rest_404_not_found)\";; esac "

	for i in "${!endpoint_function_map[@]}"; do
		controller_switch_statement+="\"$(strip_path_variable_names "${i}")\") bash_rest_response=\"\$(${endpoint_function_map[${i}]} \"\${bash_rest_endpoint_path_variables_array[@]}\")\";; "
	done

	# shellcheck disable=1091
	{ source /dev/fd/999; } 999<<DECLARE_BASH_REST_ENDPOINT_HANDLER_FUNCTION
		bash_rest_endpoint_handler() {
				  local bash_rest_incoming_request_http_method_and_endpoint="\${1}"
				  local -a bash_rest_endpoint_path_variables_array
				  local bash_rest_response
				  local bash_rest_404_response
					
					local bash_rest_endpoint_match=\$(get_endpoint_match "\${bash_rest_incoming_request_http_method_and_endpoint}")
					local bash_rest_incoming_request_uri=\$(cut -d " " -f 2 <<< \${bash_rest_incoming_request_http_method_and_endpoint})
					
					get_request_path_variables "\${bash_rest_endpoint_match}" "\${bash_rest_incoming_request_uri}" bash_rest_endpoint_path_variables_array

	        ${controller_switch_start}
				  ${controller_switch_statement}
	        ${controller_switch_end}

	        if [[ -z \${bash_rest_404_response} ]]; then
						bash_rest_print_log "INFO" "HTTP call to \${bash_rest_incoming_request_http_method_and_endpoint}"
	          echo -e "\$bash_rest_response" > "${BASH_REST_RESPONSE_FIFO_PATH}"
	        else
	        	bash_rest_print_log "ERROR" "Endpoint mapping does not exist for \${bash_rest_incoming_request_http_method_and_endpoint}"
	          echo -e "\$bash_rest_404_response" > "${BASH_REST_RESPONSE_FIFO_PATH}"
	        fi
				}
DECLARE_BASH_REST_ENDPOINT_HANDLER_FUNCTION
}

# https://dev.to/leandronsp/building-a-web-server-in-bash-part-i-sockets-2n8b
# https://gist.github.com/leandronsp/3a81e488b792235b2be73f8def2f51e6
bash_rest_handle_request() {
	local bash_rest_incoming_request
	local trline
	local headline_regex

	while read -r line; do
		trline=$(echo "$line" | tr -d '\r\n')

		[ -z "$trline" ] && break

		headline_regex='(.*?)\s(.*?)\sHTTP.*?'

		[[ "$trline" =~ $headline_regex ]] &&
			bash_rest_incoming_request=$(echo "${trline}" | sed -E "s/$headline_regex/\1 \2/")
	done

	# Defined at runtime in build_endpoint_handler_function
	bash_rest_endpoint_handler "${bash_rest_incoming_request}"
}

fifo_setup() {
	if [[ ! -d "${BASH_REST_RESPONSE_FIFO_PATH%/*}" ]]; then
		mkdir "${BASH_REST_RESPONSE_FIFO_PATH%/*}"
	fi

	if [[ ! -p "${BASH_REST_RESPONSE_FIFO_PATH}" ]]; then
		mkfifo "${BASH_REST_RESPONSE_FIFO_PATH}"
	fi
}

fifo_cleanup() {
	if [[ -p "${BASH_REST_RESPONSE_FIFO_PATH}" ]]; then
		rm -f "${BASH_REST_RESPONSE_FIFO_PATH}"
	fi

	if [[ -d "${BASH_REST_RESPONSE_FIFO_PATH%/*}" ]]; then
		rm -d "${BASH_REST_RESPONSE_FIFO_PATH%/*}"
	fi
}

print_bash_rest_init() {
	cat <<EOF

 	 ____            _           ____           _   
	| __ )  __ _ ___| |__       |  _ \ ___  ___| |_ 
	|  _ \ / _  / __| '_ \ _____| |_) / _ \/ __| __|
	| |_) | (_| \__ \ | | |_____|  _ <  __/\__ \ |_ 
	|____/ \__,_|___/_| |_|     |_| \_\___||___/\__|


$(bash_rest_print_log "INFO" "Starting Bash-Rest on port ${BASH_REST_PORT}")
EOF
}

bash_rest_print_located_annotations() {
	local -n http_method_mapping_annotations_array="${1}"
	local endpoint
	local -a endpoints_mapping
	local -a duplicate_endpoint_declarations

	for annotation in "${http_method_mapping_annotations_array[@]}"; do
		# get endpoint mapping
		http_method="$(get_annotation_http_method "${annotation}")"
		endpoint=$(get_annotation_endpoint "${annotation}")
		endpoints_mapping+=("${http_method} ${endpoint}")
		# get function associated with endpoint
		target_function=$(get_annotation_target_function "${annotation}")
		annotation_source_file=$(get_annotation_source_file "${annotation}")

		bash_rest_print_log "INFO" "Mapping ${annotation_source_file##*/}::${annotation}: ${endpoint} to ${target_function}()"
	done

	mapfile -t duplicate_endpoint_mapping_declarations < <(printf '%s\n' "${endpoints_mapping[@]}" | sort | uniq -d)

	if [[ ${#duplicate_endpoint_mapping_declarations[@]} -ne 0 ]]; then
		for duplicate_endpoint_mapping_declaration in "${duplicate_endpoint_mapping_declarations[@]}"; do
			bash_rest_print_log "FATAL" "Duplicate endpoint declaration: ${duplicate_endpoint_mapping_declaration}"
		done
		bash_rest_print_log "FATAL" "Exiting script..."
		exit 1
	fi
	echo
}

bash_rest_main() {
	trap fifo_cleanup EXIT

	print_bash_rest_init
	fifo_setup

	local -a annotations_array
	local -A method_endpoint_function_map
	get_controller_annotations annotations_array
	bash_rest_print_located_annotations annotations_array
	parse_controller_annotations method_endpoint_function_map "${annotations_array[@]}"
	build_endpoint_handler_function method_endpoint_function_map

	# Disable bash-annotations runtime checks by unsetting DEBUG trap.
	# All annotations should be built, injected, and scanned for by now
	trap - DEBUG

	while true; do
		# shellcheck disable=SC2002
		cat "${BASH_REST_RESPONSE_FIFO_PATH}" | nc -lN -p "${BASH_REST_PORT}" | bash_rest_handle_request
	done
}

bash_rest_parse_script_arguments() {
	local arguments_array=("${@}")
	echo
	for argument in "${arguments_array[@]}"; do
		if [[ -f "${argument}" ]]; then
			bash_rest_print_log "INFO" "Sourcing ${argument}"
			# shellcheck disable=1090
			source "${argument}"
		else
			bash_rest_print_log "ERROR" "Unable to source ${argument}. File not found"
		fi
	done
}

# Init script
bash_rest_parse_script_arguments "${@}"
bash_rest_main
