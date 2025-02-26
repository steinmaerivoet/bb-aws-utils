# shellcheck source=../../bb-aws-utils/lib/common.bash
[[ -z ${LIB_COMMON_LOADED} ]] && { source "${LIB_DIR:-lib}/common.bash"; }

export LIB_AWS_LOADED=1
export SERVICE_ACCOUNT=0

check_envvar AWS_DEFAULT_REGION O eu-central-1

if [[ -e /usr/local/bin/docker-credential-ecr-login ]]; then
  info "docker-credential-ecr-login already installed"
else
  info "Install docker-credential-ecr-login"
  run_cmd curl "https://amazon-ecr-credential-helper-releases.s3.us-east-2.amazonaws.com/0.5.0/linux-amd64/docker-credential-ecr-login" -o "/usr/local/bin/docker-credential-ecr-login"
  run_cmd chmod 0755 "/usr/local/bin/docker-credential-ecr-login"
fi
info "Configure ~/.docker/config.json to use docker-credential-ecr-login"
run_cmd mkdir -p ~/.docker
echo '{ "credsStore": "ecr-login" }' > ~/.docker/config.json

#######################################
# Restart a service while forcing a reload,
# which will cause the image to be downloaded
# again. This is for services that are configured
# to use the "latest" tag
#
# Globals:
#
# Arguments:
#   Cluster Name: (part of) he name of the ECS cluster where the service runs.
#                 The first match will be used.
#   ServiceName: (part of) the name that uniquely identifies the service
#                 The first match will be used.
#
# Returns:
#
#######################################
aws_force_restart_service() {
  check_envvar AWS_DEFAULT_REGION R
  [[ -z ${1} || -z ${2} ]] && \
    fail "Usage: aws_force_restart_service aws_ecs_cluster_name aws_ecs_service_name."
  local cluster=${1}; shift
  local service=${1}; shift
  local full_service_name
  local full_cluster_name

  check_command jq || install_sw jq

  info "Using the string ${cluster} to determine the full name of the cluster."
  full_cluster_name=$(aws ecs describe-clusters \
                           --cluster $(aws ecs list-clusters --output text) \
                           --query "clusters[?contains(clusterName, '${cluster}')].clusterName" | \
                      jq -r '.[0]' || true)
  info "Using the cluster ${full_cluster_name} to restart the service specified with ${service}."
  info "Using ${service} to determine the full name of the service in cluster ${full_cluster_name}."

  full_service_arn=$(aws ecs list-services \
                          --cluster "${full_cluster_name}" \
                          --query "serviceArns[?contains(@,'${service}')]" \
                          --output text)
  if [[ -z "${full_service_arn}" ]]; then
    full_service_name=""
  else
    full_service_name=$(basename "${full_service_arn}")
  fi

  if [[ -z ${full_service_name} ]]; then
    fail "No service name found that contains the string ${service} in cluster ${cluster}."
  fi

  info "Full service name is ${full_service_name}"
  info "Updating service ${full_service_name} in ECS cluster ${full_cluster_name}."
  if aws ecs update-service --cluster "${full_cluster_name}" --force-new-deployment --service "${full_service_name}"; then
    success "Service ${full_service_name} in cluster ${full_cluster_name} successfully updated."
  else
    fail "An error occurred updating ${full_service_name} in cluster ${full_cluster_name}."
  fi
}

aws_update_service() {
  check_envvar AWS_DEFAULT_REGION R
  [[ -z ${1} || -z ${2} || -z ${3} || -z ${4} || -z ${5} ]] && \
    fail "Usage: aws_update_service <aws_ecs_cluster_name> <aws_ecs_service_name> <aws_ecs_task_family> <image_tag> <image_basename>"
  local aws_ecs_cluster_name=${1}; shift
  local aws_ecs_service_name=${1}; shift
  local aws_ecs_task_family=${1}; shift
  local image_tag=${1}; shift
  local image_basename=${1}; shift

  info "Creating task definition file for ${aws_ecs_task_family} with version ${image_tag}"
  aws_ecs_create_task_definition_file "${aws_ecs_task_family}" "${image_basename}:${image_tag}"
  success "Task definition file successfully created"

  info "Registering task definition file for ${aws_ecs_task_family} with version ${image_tag}"
  aws_ecs_register_taskdefinition "${aws_ecs_task_family}"
  success "Task definition successfully registered"

  info "Update service ${aws_ecs_service_name} in cluster ${aws_ecs_cluster_name}"
  aws ecs update-service --cluster "${aws_ecs_cluster_name}" \
                         --task-definition "${AWS_ECS_NEW_TASK_DEFINITION_ARN}" \
                         --force-new-deployment \
                         --service "${aws_ecs_service_name}"
  success "Successfully updated service ${aws_ecs_service_name} in cluster ${aws_ecs_cluster_name}"
}

#######################################
# Update a service using information from SSM parameter store
#
# Globals:
#   * AWS_SKIP_DEPLOY: Do not update the service, only update the image related SSM parameters
#
# Arguments:
#   $1: AWS Profile name
#   $2: The docker image name
# Returns:
#
#######################################
aws_update_service_ssm() {
  check_envvar AWS_DEFAULT_REGION R

  [[ -z ${1} || -z ${2} ]] && \
    fail "${FUNCNAME[0]} - ${FUNCNAME[0]} aws_profile docker_image"

  local aws_profile="${1}"
  local aws_prev_profile
  local docker_image="${2}"
  local docker_image_tag
  local aws_ecs_cluster_name
  local aws_ecs_service_name
  local aws_ecs_task_family

  # Set correct profile for role on destination account to be assumed
  info "${FUNCNAME[0]} - Use ${aws_profile} as AWS_PROFILE"
  aws_prev_profile="${AWS_PROFILE:-}"
  export AWS_PROFILE="${aws_profile}"

  if maven_get_saved_current_version >/dev/null; then
    docker_image_tag="${BITBUCKET_COMMIT}-$(maven_get_saved_current_version)"
  else
    docker_image_tag="${BITBUCKET_COMMIT}"
  fi

  aws_create_or_update_ssm_parameter "/service/${PARENT_SLUG}/image" "${docker_image}:${docker_image_tag}"
  aws_create_or_update_ssm_parameter "/service/${PARENT_SLUG}/imagebasename" "${docker_image}"
  aws_create_or_update_ssm_parameter "/service/${PARENT_SLUG}/imagetag" "${docker_image_tag}"

  if [[ "${AWS_SKIP_DEPLOY:-0}" = "0" ]]; then
    aws_ecs_cluster_name=$(aws_get_ssm_parameter_by_name "/service/${PARENT_SLUG}/ecs/clustername")
    aws_ecs_service_name=$(aws_get_ssm_parameter_by_name "/service/${PARENT_SLUG}/ecs/servicename")
    aws_ecs_task_family=$(aws_get_ssm_parameter_by_name "/service/${PARENT_SLUG}/ecs/taskfamily")

    aws_update_service "${aws_ecs_cluster_name}" "${aws_ecs_service_name}" \
                       "${aws_ecs_task_family}" "${docker_image_tag}" "${docker_image}"
  fi
}

aws_get_accountid_from_sts_getidentity() {
  aws sts get-caller-identity --query Account --output text
}

aws_update_service_substr() {
  check_envvar AWS_DEFAULT_REGION R
  check_envvar ENVIRONMENT R
  check_envvar AWS_DEFAULT_REGION O "eu-central-1"

  [[ -z ${1} || -z ${2} || -z ${3} || -z ${4} || -z ${5} ]] && \
    fail "Usage: aws_update_service_substr <aws_ecs_cluster_name> <aws_ecs_service_substr> <aws_ecs_task_family> <image_tag> <image_basename>"

  if [[ -z ${AWS_ACCOUNTID_TARGET} ]]; then
    AWS_ACCOUNTID_TARGET=$(aws_get_accountid_from_sts_getidentity)
  fi

  local aws_ecs_cluster_name="${1}"
  local aws_ecs_service_substr="${2}"
  local aws_ecs_task_family="${3}"
  local docker_image_tag="${4}"
  local docker_image_basename="${5}"

  local aws_ecs_service_name
  aws_ecs_service_name=$(aws ecs list-services --cluster "${aws_ecs_cluster_name}" --output text | grep "${aws_ecs_service_substr}" | awk -F'/' '{print $3}')

  local docker_image="${AWS_ACCOUNTID_TARGET}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com/${docker_image_basename}-${ENVIRONMENT}"

  info "aws_update_service \"${aws_ecs_cluster_name}\" \"${aws_ecs_service_name}\" \"${aws_ecs_task_family}\" \"${docker_image_tag}\" \"${docker_image}\""
  aws_update_service "${aws_ecs_cluster_name}" "${aws_ecs_service_name}" "${aws_ecs_task_family}" "${docker_image_tag}" "${docker_image}"
}


#######################################
# Create a task definition file based on
# the current task definition, replacing
# the image name with the new version
#
# Globals:
#
# Arguments:
#   Image Name: The name of the image, including tag
#
# Returns:
#   None
#######################################
aws_ecs_create_task_definition_file() {
  check_command aws || install_awscli
  check_command jq || install_sw jq
  [[ -z ${1} || -z ${2} ]] && fail "Usage: aws_ecs_create_task_definition_file <aws_ecs_task_family> <docker_image>"
  local aws_ecs_task_family=${1}; shift
  local aws_image=${1}; shift

  aws ecs describe-task-definition --task-definition "${aws_ecs_task_family}" \
                                   --query 'taskDefinition' | \
                                   jq "del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy)" | \
                                   jq ".containerDefinitions[0].image = \"${aws_image}\"" > /tmp/taskdefinition.json

  if is_debug_enabled; then
    debug "Content of task definition file -- START"
    cat /tmp/taskdefinition.json
    debug "Content of task definition file -- END"
  fi
}

aws_ecs_register_taskdefinition() {
  # Limitation: only supports task definitions with 1 containerDefinition
  check_command aws || install_awscli
  check_command jq || install_sw jq
  [[ -z ${1} ]] && fail "Usage: aws_ecs_register_taskdefinition <aws_ecs_task_family>"
  local aws_ecs_task_family=${1}; shift
  local RESULT

  info "Registering a new task definition for ${aws_ecs_task_family}"
  RESULT=$(aws ecs register-task-definition --family "${aws_ecs_task_family}" --cli-input-json file:///tmp/taskdefinition.json)
  AWS_ECS_NEW_TASK_DEFINITION_ARN=$(echo "${RESULT}" | jq -r '.taskDefinition.taskDefinitionArn')
  success "Successfully registered new task definition for ${aws_ecs_task_family}"
  info "New task definition ARN is ${AWS_ECS_NEW_TASK_DEFINITION_ARN}"
}

# Check if the value of AWS_PROFILE is configured as a Service Account in the
# repo this is run in
aws_is_service_account_available() {
  if [[ -n "${AWS_PROFILE}" ]]; then
    for profile in ${SA_ACCOUNT_LIST:-empty}; do
      if [[ "${profile}" == "${AWS_PROFILE}" ]]; then
        return 0
      fi
    done
  else
    return 0
  fi

  return 1
}

aws_set_service_account_config() {
  local account

  info "Start creation of AWS CLI config and credentials file, if applicable"
  [[ -z ${AWS_CONFIG_BASEDIR} ]] && AWS_CONFIG_BASEDIR=~/.aws
  if [[ -n ${SA_ACCOUNT_LIST} ]]; then
    check_command aws || install_awscli

    mkdir -p "${AWS_CONFIG_BASEDIR}"
    info "Start creation of ${AWS_CONFIG_BASEDIR}/credentials"
    {
      for account in ${SA_ACCOUNT_LIST}; do
        echo "[${account}_SOURCE]"
        echo "aws_access_key_id=$(_indirection ACCESS_KEY_ID ${account})"
        echo "aws_secret_access_key=$(_indirection SECRET_ACCESS_KEY ${account})"
        echo "region=eu-central-1"
        echo ""
      done
    } > ${AWS_CONFIG_BASEDIR}/credentials

    info "Start creation of ${AWS_CONFIG_BASEDIR}/config"
    {
      (( counter = 0 )) || true
      for account in ${SA_ACCOUNT_LIST}; do
        local role_arn
        local account_id

        role_arn="$(_indirection ROLE_TO_ASSUME ${account})"
        account_id="$(_indirection ACCOUNT_ID ${account})"

        if [[ -z ${role_arn} ]]; then
          role_arn="arn:aws:iam::${account_id}:role/ServiceAccount/cicd"
        fi
        if [[ ${counter} -eq 0 ]]; then
          echo "[profile default]"
          echo "source_profile=${account}_SOURCE"
          echo "role_arn=${role_arn}"
          echo ""
        fi
        echo "[profile ${account}]"
        echo "source_profile=${account}_SOURCE"
        echo "role_arn=${role_arn}"
        echo ""
        (( counter++ )) || true
      done
    } > ${AWS_CONFIG_BASEDIR}/config

    debug "Show AWS config and credentials file"
    cat ${AWS_CONFIG_BASEDIR}/config
    cat ${AWS_CONFIG_BASEDIR}/credentials

    info "Unsetting existing AWS envvars to enforce usage of ~/.aws/* files"
    unset AWS_ACCESS_KEY_ID
    unset AWS_SECRET_ACCESS_KEY
    SERVICE_ACCOUNT=1
    aws sts get-caller-identity || true
  else
    info "Skipping creation of AWS CLI config and credentials because the required"
    info "environment variable SA_ACCOUNT_LIST is not set"
  fi
}

aws_set_codeartifact_token() {
  if [[ -n ${AWS_CODEARTIFACT_DOMAIN} && -n ${AWS_CODEARTIFACT_DOMAIN_OWNER} ]]; then
    info "Trying to get the CODEARTIFACT_AUTH_TOKEN"
    check_command aws || install_awscli
    if CODEARTIFACT_AUTH_TOKEN=$(aws codeartifact get-authorization-token  \
                                --domain "${AWS_CODEARTIFACT_DOMAIN}" \
                                --domain-owner "${AWS_CODEARTIFACT_DOMAIN_OWNER}" \
                                --query authorizationToken \
                                --output text); then
      success "Successfully retrieved CODEARTIFACT_AUTH_TOKEN"
      export CODEARTIFACT_AUTH_TOKEN
    else
      error "Unable to get CODEARTIFACT_AUTH_TOKEN for:"
      error "  Domain:       ${AWS_CODEARTIFACT_DOMAIN}"
      error "  Domain Owner: ${AWS_CODEARTIFACT_DOMAIN_OWNER}"
      fail "Exiting ..."
    fi
  else
    info "Skipping CODEARTIFACT_AUTH_TOKEN generation because AWS_CODEARTIFACT_DOMAIN"
    info "  and/or AWS_CODEARTIFACT_DOMAIN_OWNER are not set"
  fi
}

aws_credentials_ok() {
  install_awscli

  if aws sts get-caller-identity >/dev/null 2>&1; then
    return 0
  else
    return 1
  fi
}

aws_s3_deploy() {
  check_envvar S3_BUCKET R
  check_envvar LOCAL_PATH O "workdir"
  check_envvar ACL O "private"

  install_awscli

  aws_credentials_ok || fail "No valid AWS credentials found. Exiting ..."
  [[ ! -d ${LOCAL_PATH} ]] && fail "Directory ${LOCAL_PATH} does not exist. Exiting ..."

  cd "${LOCAL_PATH}"
  info "${FUNCNAME[0]} - Starting deploy of the payload in ${LOCAL_PATH} to s3://${S3_BUCKET}/${S3_PREFIX:-} with ACL ${ACL}"
  aws s3 cp --acl "${ACL}" --recursive . "s3://${S3_BUCKET}/${S3_PREFIX:-}"
  info "${FUNCNAME[0]} - Finished deploying the payload in ${LOCAL_PATH} to s3://${S3_BUCKET}/${S3_PREFIX:-} with ACL ${ACL}"

  cd - > /dev/null || fail "Previous (cd -) directory does not exist. Exiting ..."
}

aws_create_or_update_ssm_parameter() {
  local name="${1:-}"
  local value="${2:-}"
  local secret="${3:-no}"

  check_envvar name R
  check_envvar value R

  install_awscli

  if [[ "${secret}" = "no" ]]; then
    info "${FUNCNAME[0]} - Set SSM parameter \"${name}\" to \"${value}\"."
  else
    info "${FUNCNAME[0]} - Set SSM parameter \"${name}\" to \"************\"."
  fi

  cat > mmparameter.json << EOF
{ "Value": "${value}" }
EOF
  aws ssm put-parameter --name "${name}" --cli-input-json file://mmparameter.json --type String --overwrite
  rm -f mmparameter.json
}

aws_get_ssm_parameter_by_name() {
  local name="${1:-}"
  local jmesexp="${2:-}"

  check_envvar name R

  info "Retrieving parameter ${name} from SSM."
  local ssm_parameter_value
  if [[ -n ${jmesexp} ]]; then
    info "Applying ${jmesexp} to the output"
    # The output is considered JSON and the jmesexp expression is applied
    check_command jq || install_sw jq
    ssm_parameter_value=$(aws ssm get-parameters --names "${name}" | jq -r "${jmesexp}")
    if [[ $? -eq 0 ]]; then
      success "Successfully retrieved ${name} and applied ${jmesexp}."
      success "${ssm_parameter_value}"
    else
      fail "Error retrieving ${name} from SSM, exiting ..."
    fi
  else
    ssm_parameter_value=$(aws ssm get-parameters --names "${name}" --query "Parameters[].Value" --output text)
    if [[ $? -eq 0 ]]; then
      success "Parameter ${name} successfully retrieved from SSM."
      debug   "${ssm_parameter_value}"
    else
      fail "Error retrieving ${name} from SSM, exiting ..."
    fi
  fi

  echo "$ssm_parameter_value"
}

aws_get_ssm_parameter_by_path() {
  local path="${1:-}"
  local jmesexp="${2:-}"

  check_envvar path R

  info "Retrieving parameters with path ${path} from SSM."
  local ssm_parameter_value
  if [[ -n ${jmesexp} ]]; then
    info "Applying ${jmesexp} to the output"
    # The output is considered JSON and the jmesexp expression is applied
    check_command jq || install_sw jq
    ssm_parameter_value=$(aws ssm get-parameters-by-path --path "${path}" | jq -r "${jmesexp}")
    if [[ $? -eq 0 ]]; then
      success "Successfully retrieved ${path} and applied ${jmesexp}."
      debug   "${ssm_parameter_value}"
    else
      fail "Error retrieving ${path} from SSM, exiting ..."
    fi
  else
    ssm_parameter_value=$(aws ssm get-parameters-by-path --path "${path}" --query "Parameters[].Value" --output text)
    if [[ $? -eq 0 ]]; then
      success "Successfully retrieved ${path} from SSM."
      debug   "${ssm_parameter_value}"
    else
      fail "Error retrieving ${path} from SSM, exiting ..."
    fi
  fi

  echo "$ssm_parameter_value"
}

aws_delete_ssm_parameter() {
  local name="${1:-}"
  check_envvar name R

  info "Deleting parameter ${name} from SSM."
  if aws ssm delete-parameters --names "${name}" >/dev/null 2>&1; then
    success "Parameter ${name} successfully removed from SSM."
  else
    error "Error removing parameter ${name} from SSM."
  fi
}

aws_cloudfront_invalidate() {
  check_envvar CLOUDFRONT_DISTRIBUTION_ID R
  check_envvar PATHS O "/*"

  install_awscli

  info "Invalidating path ${PATHS} on CloudFront distribution with ID ${CLOUDFRONT_DISTRIBUTION_ID}"
  aws cloudfront create-invalidation --distribution-id "${CLOUDFRONT_DISTRIBUTION_ID}" --paths "${PATHS}"
}

#######################################
# Run aws_cdk_determine_version
#
# Globals:
#
# Arguments:
#
# Returns:
#    * Sets AWS_CDK_VERSION to aws-cdk version found in package.json, if any
#
#######################################
aws_cdk_determine_version() {
  # Determine the aws-cdk version to use
  if npx npm list aws-cdk >/dev/null 2>&1; then
    local aws_cdk_pkg
    aws_cdk_pkg=$(npx npm list aws-cdk)
    AWS_CDK_VERSION="${aws_cdk_pkg##*@}"
    info "Found aws-cdk version in package.json: ${AWS_CDK_VERSION}"
    info "Will use this version to deploy the infrastructure"
  else
    if npx npm list aws-cdk-lib >/dev/null 2>&1; then
      local aws_cdk_pkg
      aws_cdk_pkg=$(npx npm list aws-cdk-lib)
      AWS_CDK_VERSION="${aws_cdk_pkg##*@}"
      info "Found aws-cdk version in package.json: ${AWS_CDK_VERSION}"
      info "Will use this version to deploy the infrastructure"
    else
      warning "Could not determine aws-cdk version from package.json, using ${AWS_CDK_VERSION:-1.91.0}"
    fi
  fi
}

#######################################
# Use the aws_cdk_deploy function to:
#
#     * Deploy a single service, if used in a service repository. Optionally (when
#       the envvar AWS_CDK_DEPLOY_SKIP_CDK_DEPLOY is set and <> 0), the ECS service
#       will not be deployed, only the SSM parameter holding the container image to use
#       will be changed.
#     * Deploy the complete aws-cdk stack (when called without the optional DockerImage
#       parameter.
#
# NOTES:
#     * The repo ${aws_cdk_infra_repo} will always be cloned and the branch
#       ${aws_cdk_infra_repo_branch} will be checked out. ALSO WHEN THIS FUNCTION
#       IS STARTED BY THE PIPELINE OF THE ${aws_cdk_infra_repo} REPO !!!!!!
#     * The function will try to determine the aws-cdk version to use from the
#       NPM dependencies of ${aws_cdk_infra_repo}. Only if the version cannot be
#       determined will the ${AWS_CDK_VERSION} envvar be used.
#
# Expects:
#     * Project was built with maven_build or maven_release_build from
#       the maven.lib in this repo (because it saves the maven version to a file)
#     * Docker image is tagged with ${BITBUCKET_COMMIT}-<version>
#     * If the BB pipeline deploy step using this function is different from the build step
#       in the pipeline, the build step should have:
#           artifacts:
#             - artifacts/**
#
# Globals:
#
# Arguments:
#   Aws profile: The name of the AWS profile to set for the aws cdk permissions.
#       This only works if Service Accounts are used and the appropriate pipeline
#       environment variables are set in the BB project
#   Deploy Repo: The git repository that contains the aws-cdk code for the project
#       and that will be used to update the environment.
#   Deploy Repo Branch: The branch of the deploy repository to checkout. This
#       depends on the target environment and is standardized to:
#           * tst: for the test environment
#           * stg: for the staging environment
#           * master: for production
#       This is also the value used in "-c ENV=xxxx"
#   DockerImage (optional): The docker image to use, without the tag, but with the host part
#       (for non docker hub registries). If this argument is not present, a IaC only
#       deploy is performed, without any change to any service, and without performing
#       the clone of the IaC repo (because this only makes sense in the pipeline for
#       the IaC repo.
#       An example:
#           123456789012.dkr.ecr.eu-central-1.amazonaws.com/org/my-image
#
# Returns:
#
#######################################
aws_cdk_deploy() {
  [[ -z ${1} ]] && fail "${FUNCNAME[0]} - aws_cdk_deploy aws_profile [iac_repo] [iac_repo_branch] [docker_image]"

  local aws_profile="${1}"
  local aws_prev_profile
  local aws_cdk_infra_repo="${2:-}"
  local aws_cdk_infra_repo_branch="${3:-master}"
  local docker_image="${4:-}"
  local aws_cdk_env="${aws_cdk_infra_repo_branch}"

  [[ ${aws_cdk_env} == master ]] && aws_cdk_env="prd"

  # If probably a production branch and it does not exist: use master
  if [[ ${aws_cdk_infra_repo_branch} =~ pr.*d ]]; then
    if ! git_branch_exists "${aws_cdk_infra_repo}" "${aws_cdk_infra_repo_branch}"; then
      info "No branch ${aws_cdk_infra_repo_branch} in repo ${aws_cdk_infra_repo}, using master instead."
      aws_cdk_infra_repo_branch="master"
    fi
  fi

  if [[ -n ${aws_cdk_infra_repo} ]]; then
    info "Clone the infra deploy repo"
    git clone -b "${aws_cdk_infra_repo_branch}" "${aws_cdk_infra_repo}" ./aws-cdk-deploy
    # shellcheck disable=SC2164
    cd aws-cdk-deploy
  else
    info "${FUNCNAME[0]} - Using current repo ${BITBUCKET_REPO_SLUG}";
    info "${FUNCNAME[0]} -   and branch ${aws_cdk_infra_repo_branch} as IaC code repo";
  fi

  # Set correct profile for role on destination account to be assumed
  info "${FUNCNAME[0]} - Use ${aws_profile} as AWS_PROFILE"
  aws_prev_profile="${AWS_PROFILE:-}"
  export AWS_PROFILE="${aws_profile}"

  # Update the SSM parameter /service/${PARENT_SLUG}/image to trigger service update
  # when running the aws cdk infrastructure deploy, but only if docker_image is not empty
  if [[ -n ${docker_image} ]]; then
    local ssm_parameter_value
    local docker_image_tag

    if [[ -n "${DOCKER_TAG}" ]]; then
      docker_image_tag="${DOCKER_TAG}"
    else
      if maven_is_maven_project; then
        maven_get_current_versions
        if  [[ "${MAVEN_CURRENT_RELEASE_VERSION}" = "NA" ]]; then
          # The build was a snapshot build, use the snapshot version in the tag
          info "Release version from BB artifacts is NA, the build was a snapshot build, and the snapshot version is used in the tag"
          docker_image_tag="${BITBUCKET_COMMIT}-${MAVEN_CURRENT_SNAPSHOT_VERSION}"
        else
          if [[ -n ${MAVEN_CURRENT_RELEASE_VERSION} ]]; then
            info "Release version from BB artifacts is not NA and exists, the build was a release build, and the release version is used in the tag"
            docker_image_tag="${BITBUCKET_COMMIT}-${MAVEN_CURRENT_RELEASE_VERSION}"
          else
            info "No versions have been found in the BB artifacts, no version is used in the tag"
            docker_image_tag="${BITBUCKET_COMMIT}"
          fi
        fi
      else
        docker_image_tag="${BITBUCKET_COMMIT}"
      fi
    fi

    info "Use tag ${docker_image_tag}"
    ssm_parameter_value="${docker_image}:${docker_image_tag}"
    info "${FUNCNAME[0]} - Create or update the /service/${PARENT_SLUG}/image SSM parameter with value:"
    info "  ${ssm_parameter_value}"
    aws_create_or_update_ssm_parameter "/service/${PARENT_SLUG}/image" "${ssm_parameter_value}"
    aws_create_or_update_ssm_parameter "/service/${PARENT_SLUG}/imagebasename" "${docker_image}"
    aws_create_or_update_ssm_parameter "/service/${PARENT_SLUG}/imagetag" "${docker_image_tag}"
  else
    info "${FUNCNAME[0]} - IaC only deploy, no service will be updated, unless the service's image"
    info "${FUNCNAME[0]} - in SSM parameter store was updated manually or by using this function"
    info "${FUNCNAME[0]} - with the envvar AWS_CDK_DEPLOY_SKIP_CDK_DEPLOY set to 1."
  fi

  if [[ ${AWS_CDK_DEPLOY_SKIP_CDK_DEPLOY:-0} -ne 1 ]]; then
    npm install --quiet --no-progress
    aws_cdk_determine_version
    info "Starting command \"npx aws-cdk@${AWS_CDK_VERSION:-1.91.0} deploy --all -c ENV=\"${aws_cdk_env}\" --require-approval=never\""
    npx aws-cdk@${AWS_CDK_VERSION:-1.91.0} deploy --all -c ENV="${aws_cdk_env}" --require-approval=never
    info "${FUNCNAME[0]} - IaC deploy successfully executed."
  else
    info "Skipping cdk deploy because AWS_CDK_DEPLOY_SKIP_CDK_DEPLOY is set to ${AWS_CDK_DEPLOY_SKIP_CDK_DEPLOY}"
  fi

  export AWS_PROFILE="${aws_prev_profile}"
}

#######################################
# Run cdk destroy to remove the stacks.
#
# Globals:
#
# Arguments:
#   Aws profile: The name of the AWS profile to set for the aws cdk permissions.
#       This only works if Service Accounts are used and the appropriate pipeline
#       environment variables are set in the BB project
#   Deploy Repo: The git repository that contains the aws-cdk code for the project
#       and that will be used to update the environment.
#   Deploy Repo Branch: The branch of the deploy repository to checkout. This
#       depends on the target environment and is standardized to:
#           * tst: for the test environment
#           * stg: for the staging environment
#           * master: for production
#       This is also the value used in "-c ENV=xxxx"
#   Stacks (optional): The list of stacks to destroy
#
# Returns:
#
#######################################
aws_cdk_destroy() {
  [[ -z ${1} || -z ${2} || -z ${3}  ]] && \
    fail "${FUNCNAME[0]} - aws_cdk_destroy aws_profile deploy_repo deploy_repo_branch"

  local aws_profile="${1}"
  local aws_prev_profile
  local aws_cdk_infra_repo="${2:-}"
  local aws_cdk_infra_repo_branch="${3:-}"
  local aws_cdk_env="${aws_cdk_infra_repo_branch}"
  local aws_cdk_stacks="${4:-}"

  [[ ${aws_cdk_env} == master ]] && aws_cdk_env="prd"

  if [[ -n ${aws_cdk_infra_repo} ]]; then
    info "Clone the infra deploy repo"
    git clone -b "${aws_cdk_infra_repo_branch}" "${aws_cdk_infra_repo}" ./aws-cdk-deploy
    # shellcheck disable=SC2164
    cd aws-cdk-deploy
  else
    info "${FUNCNAME[0]} - Using current repo ${BITBUCKET_REPO_SLUG}";
    info "${FUNCNAME[0]} -   and branch ${aws_cdk_infra_repo_branch} as IaC code repo";
  fi

  # Set correct profile for role on destination account to be assumed
  info "${FUNCNAME[0]} - Use ${aws_profile} as AWS_PROFILE"
  aws_prev_profile="${AWS_PROFILE:-}"
  export AWS_PROFILE="${aws_profile}"

  npm install --quiet --no-progress

  aws_cdk_determine_version

  if [[ -n ${aws_cdk_stacks} ]]; then
    info "Starting command \"cdk destroy --force -c ENV=\"${aws_cdk_env}\" --require-approval=never\" ${aws_cdk_stacks}"
    npx aws-cdk@${AWS_CDK_VERSION:-1.91.0} destroy --force -c ENV="${aws_cdk_env}" --require-approval=never ${aws_cdk_stacks}
  else
    info "Starting command \"npx aws-cdk@${AWS_CDK_VERSION:-1.91.0} destroy --force --all -c ENV=\"${aws_cdk_env}\" --require-approval=never\""
    npx aws-cdk@${AWS_CDK_VERSION:-1.91.0} destroy --force --all -c ENV="${aws_cdk_env}" --require-approval=never
  fi

  info "${FUNCNAME[0]} - IaC destroy successfully executed."

  export AWS_PROFILE="${aws_prev_profile}"
}

#######################################
# Deploy all stacks from the aws-cdk repo where the pipeline runs,
# except the stacks passed as an argument to this function.
#
# Globals:
#
# Arguments:
#   Aws profile: The name of the AWS profile to set for the aws cdk permissions.
#       This only works if Service Accounts are used and the appropriate pipeline
#       environment variables are set in the BB project
#   Node Env: The environment to deploy to. This is used to set the NODE_ENV environment
#       variable that is used by the JS config library
#   Stack names to exclude: A space separated list of 0 or more stacks to exclude. If no
#       stack is passed for exclusion, all stacks wll be deployed.
#
#
# Returns:
#
#######################################
aws_cdk_deploy_all_with_exclusions() {
  if [[ -z ${1} || -z ${2} ]]; then
    fail "${FUNCNAME[0]} - aws_cdk_destroy aws_profile deploy_repo deploy_repo_branch"
  fi

  local aws_profile="${1}"
  local aws_prev_profile
  local aws_cdk_stacks_to_deploy

  export NODE_ENV="${2}"

  # Get rid of the first 2 arguments, what remains are the stacks to exclude
  shift
  shift

  # Set correct profile for role on destination account to be assumed
  info "${FUNCNAME[0]} - Use ${aws_profile} as AWS_PROFILE"
  aws_prev_profile="${AWS_PROFILE:-}"
  export AWS_PROFILE="${aws_profile}"

  aws_cdk_get_all_stacks

  info "Removing stacks to exclude from ${AWS_CDK_ALL_STACKS}"
  for stack in ${AWS_CDK_ALL_STACKS}; do
    local exclude_stack=0
    for stack_to_exclude in "${@}"; do
      if [[ ${stack} == ${stack_to_exclude} ]]; then
        exclude_stack=1
      fi
    done
    if [[ ${exclude_stack} -eq 0 ]]; then
      info "Adding ${stack} to the list of stacks to deploy"
      aws_cdk_stacks_to_deploy="${aws_cdk_stacks_to_deploy} ${stack}"
    fi
  done

  info "Remaining stacks to deploy: ${aws_cdk_stacks_to_deploy}"
  info "Starting deploy of ${aws_cdk_stacks_to_deploy}"

  npx aws-cdk@${AWS_CDK_VERSION:-2.50.0} deploy ${aws_cdk_stacks_to_deploy} --require-approval=never

  export AWS_PROFILE="${aws_prev_profile}"
}

#######################################
# Disable LB logs for the ALB ARN passed to the function
#
# Globals:
#
# Arguments:
#
# Returns:
#   Sets the environment variable AWS_CDK_ALL_STACKS
#
#######################################
aws_cdk_get_all_stacks() {

  aws_cdk_determine_version

  info "Running aws-cdk synth to generate the Cloudformation templates in cdk.out"
  npx aws-cdk@${AWS_CDK_VERSION:-2.50.0} synth

  cd cdk.out
  for file in *.template.json; do
    info "Adding ${file%%.template.json} to AWS_CDK_ALL_STACKS"
    AWS_CDK_ALL_STACKS="${AWS_CDK_ALL_STACKS} ${file%%.template.json}"
  done

  cd -

  export AWS_CDK_ALL_STACKS
  info "All stacks: ${AWS_CDK_ALL_STACKS}"
}

#######################################
# Disable LB logs for the ALB ARN passed to the function
#
# Globals:
#
# Arguments:
#   ALB ARN: The load balancer ARN
#
# Returns:
#
#######################################
aws_disable_alb_logging() {
  local alb_arn
  alb_arn="${1:-}"

  info "Disabling logging for load balancer ${alb_arn}"
  aws elbv2 modify-load-balancer-attributes \
    --load-balancer-arn "${alb_arn}" \
    --attributes Key=access_logs.s3.enabled,Value=false
  success "Logging for load balancer ${alb_arn} successfully disabled"
}

#######################################
# Apply secrets from a file containing to AWS SSM Parameter store. Each line in the file has to look
# like this:
#  key=value
#  key=ssm::ssmParametername
#
# In the second form:
#   * ssmParametername is a SSM parameter in the parameter store in the same account
#     and region as the target SSM parameter.
#   * the source value cannot be a multiline string
#
# SSM parameters with a name starting with "/config" will be removed unless present in the secrets file.
# Other SSM parameters that are removed from the secrets file will not be automatically cleaned up.
#
# Globals:
#
# Arguments:
#
# Returns:
#
#######################################
aws_apply_secrets() {

  if [[ ! -e "${BITBUCKET_CLONE_DIR}/secrets" ]]; then
    info "secrets: ${BITBUCKET_CLONE_DIR}/secrets not found, will not apply SSM parameter store variables"
    return 0
  fi

  check_command jq || install_sw jq

  info "secrets: Creating SSM parameters"

  aws_get_ssm_parameter_by_path "/config" ".Parameters[].Name" | sort > existing_keys

  info "Creating and updating SSM parameters."

  is_debug_enabled && run_cmd cat "${BITBUCKET_CLONE_DIR}/secrets"
  is_debug_enabled && run_cmd ls -l "${BITBUCKET_CLONE_DIR}/secrets"
  is_debug_enabled && run_cmd ls -l "existing_keys"
  is_debug_enabled && run_cmd cat "existing_keys"

  while read secret; do
    debug "In loop reading secrets file"
    debug "   ${secret}"
    key=${secret%%=*}
    val=${secret#*=}
    if [[ $val = ssm::* ]]; then
      info "Get ${val} from AWS SSM paramater store ..."
      ssm_parameter_name="${val##ssm::}"
      val=$(aws_get_ssm_parameter_by_name "${ssm_parameter_name}")
    fi
    if [[ -n "${key}" && -n "${val}" ]]; then
      info "Add SSM parameter \"${key}\"."
      aws_create_or_update_ssm_parameter "${key}" "${val}" "yes"
    else
      info "Key (${key}) or Val (${val}) are empty, skipping SSM parameter creation."
    fi
  done < "${BITBUCKET_CLONE_DIR}/secrets"

  info "Cleaning up obsolete SSM parameters."
  while read existing_secret; do
    if [[ -n  ${existing_secret} ]]; then
      if grep -q "^${existing_secret}=" secrets; then
        info "Secret \"${existing_secret}\" in secrets, not deleting."
      else
        info "Secret \"${existing_secret}\" not in secrets, deleting ..."
        aws_delete_ssm_parameter "${existing_secret}"
      fi
    fi
  done < existing_keys
}

#######################################
#
#
# Globals:
#
# Arguments:
#
# Returns:
#
#######################################
aws_set_service_instance_count() {
  local cluster_name="${1:-}"
  local service_name="${2:-}"
  local instance_count="${3:-}"

  [[ -z "${cluster_name}" ]] && fail "aws_set_service_instance_count requires cluster name as first argument"
  [[ -z "${service_name}" ]] && fail "aws_set_service_instance_count requires service name as second argument"
  [[ -z "${instance_count}" ]] && instance_count=1

  info "aws - Set service instance count for service ${service_name} in cluster ${cluster_name} to ${instance_count}"
  if aws ecs update-service \
    --cluster "${cluster_name}" \
    --service "${service_name}" \
    --force-new-deployment \
    --desired-count ${instance_count}; then
    success "aws - Successfully set service instance count for service ${service_name} in cluster ${cluster_name} to ${instance_count}"
  else
    warning "Failed to restart service \"${service_name}\" in cluster \"${cluster_name}\" with instance count \"${instance_count}\"."
  fi
}
