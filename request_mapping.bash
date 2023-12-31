#!/usr/bin/env bash

# shellcheck disable=2034,2154

source "${BASH_REST_PROJECT_BASE_DIRECTORY}/modules/bash-annotations/src/bash-annotations.bash"
import interfaces/inject.bash

@inject PRE
get_mapping() {
	local bash_rest_endpoint="${1}"
	local bash_rest_target_annotation=${inject_annotated_function}
	local bash_rest_function_source_file=${annotation_source_file}
}

@inject PRE
post_mapping() {
	local bash_rest_endpoint="${1}"
	local bash_rest_target_annotation=${inject_annotated_function}
	local bash_rest_function_source_file=${annotation_source_file}
}
@inject PRE
put_mapping() {
	local bash_rest_endpoint="${1}"
	local bash_rest_target_annotation=${inject_annotated_function}
	local bash_rest_function_source_file=${annotation_source_file}
}

@inject PRE
delete_mapping() {
	local bash_rest_endpoint="${1}"
	local bash_rest_target_annotation=${inject_annotated_function}
	local bash_rest_function_source_file=${annotation_source_file}
}
