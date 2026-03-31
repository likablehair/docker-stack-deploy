#!/bin/bash
set -e

# Use root home folder
SSH_DIR="/root/.ssh"
SSH_KEY="${SSH_DIR}/docker"
SSH_KEY_CERT="${SSH_DIR}/docker-cert.pub"
KNOWN_HOSTS="${SSH_DIR}/known_hosts"
ENV_FILE_PATH="/root/.env"

login() {
  echo "${PASSWORD}" | docker login "${REGISTRY}" -u "${USERNAME}" --password-stdin
}

configure_ssh() {
  mkdir -p "${SSH_DIR}"
  printf '%s' "UserKnownHostsFile=${KNOWN_HOSTS}" > "${SSH_DIR}/config"
  chmod 600 "${SSH_DIR}/config"
}

configure_ssh_key() {
  if [ -n "$REMOTE_PRIVATE_KEY_FILE" ]; then
    cat "$REMOTE_PRIVATE_KEY_FILE" > "${SSH_KEY}"
  else
    printf '%s' "$REMOTE_PRIVATE_KEY" > "${SSH_KEY}"
  fi

  if [ "$WITH_CERT" = "true" ] || [ -n "$WITH_CERT" ] && [ "$WITH_CERT" != "false" ]; then
    if [ -n "$REMOTE_PRIVATE_KEY_CERT_FILE" ]; then
      cat "$REMOTE_PRIVATE_KEY_CERT_FILE" > "${SSH_KEY_CERT}"
    else
      printf '%s' "$REMOTE_PRIVATE_KEY_CERT" > "${SSH_KEY_CERT}"
    fi
    chmod 600 "${SSH_KEY_CERT}"
  fi

  lastLine=$(tail -n 1 "${SSH_KEY}")
  if [ "${lastLine}" != "" ]; then
    printf '\n' >> "${SSH_KEY}";
  fi
  chmod 600 "${SSH_KEY}"
  eval "$(ssh-agent)"
  ssh-add "${SSH_KEY}"
}

configure_env_file() {
  if [ "${DEBUG}" != "0" ]; then
    echo "Environment Variables Already present: ${ENV_FILE_PATH}"

    echo "Environment Variables: Adding additional values from ${ENV_FILE}"
    cat "${ENV_FILE}"
  fi
  cat "$ENV_FILE" > "${ENV_FILE_PATH}"
  env_file_len=$(grep -v '^#' ${ENV_FILE_PATH}|grep -v '^$' -c)
  if [[ $env_file_len -gt 0 ]]; then
    echo "Environment Variables: Additional values"
    if [ "${DEBUG}" != "0" ]; then
      echo "Environment vars before: $(env|wc -l)"
      echo "Environment vars values before: $(env)"
    fi
    # shellcheck disable=SC2046
    export $(grep -v '^#' ${ENV_FILE_PATH} | grep -v '^$' | xargs -d '\n')
    if [ "${DEBUG}" != "0" ]; then
      echo "Environment vars after: $(env|wc -l)"
      echo "Environment vars values before: $(env)"
    fi
  fi
}

configure_ssh_host() {
  ssh-keyscan -p "${REMOTE_PORT}" "${REMOTE_HOST}" > "${KNOWN_HOSTS}"
  chmod 600 "${KNOWN_HOSTS}"
}

connect_ssh() {
  cmd="ssh"
  if [ "${SSH_VERBOSE}" != "" ]; then
    cmd="ssh ${SSH_VERBOSE}"
  fi
  user=$(${cmd} -p "${REMOTE_PORT}" "${REMOTE_USER}@${REMOTE_HOST}" whoami)
  if [ "${user}" != "${REMOTE_USER}" ]; then
    exit 1;
  fi
}

deploy() {
  local IFS=','
  local compose_args=()

  echo "$STACK_FILE"

  for file in ${STACK_FILE}; do
    clean_file=$(echo "$file" | xargs)
    echo "Deploy: Adding stack file ${clean_file}"
    compose_args+=("-c" "$clean_file")
  done

  docker stack deploy --with-registry-auth "${compose_args[@]}" "${STACK_NAME}"
}

check_deploy() {
  echo "Deploy: Checking status"
  /stack-wait.sh -t "${DEPLOY_TIMEOUT}" "${STACK_NAME}"
}

[ -z ${DEBUG+x} ] && export DEBUG="0"

# ADDITIONAL ENV VARIABLES
if [[ -z "${ENV_FILE}" ]]; then
  export ENV_FILE=""
else
  configure_env_file;
fi

# SET DEBUG
if [ "${DEBUG}" != "0" ]; then
  OUT=/dev/stdout;
  SSH_VERBOSE="-vvv"
  echo "Verbose logging"
else
  OUT=/dev/null;
  SSH_VERBOSE=""
fi

# PROCEED WITH LOGIN
if [ -z "${USERNAME+x}" ] || [ -z "${PASSWORD+x}" ]; then
  echo "Container Registry: No authentication provided"
else
  [ -z ${REGISTRY+x} ] && export REGISTRY=""
  if login > /dev/null 2>&1; then
    echo "Container Registry: Logged in ${REGISTRY} as ${USERNAME}"
  else
    echo "Container Registry: Login to ${REGISTRY} as ${USERNAME} failed"
    exit 1
  fi
fi

if [[ -z "${DEPLOY_TIMEOUT}" ]]; then
  export DEPLOY_TIMEOUT=600
fi

# CHECK REMOTE VARIABLES
if [[ -z "${REMOTE_HOST}" ]]; then
  echo "Input remote_host is required!"
  exit 1
fi
if [[ -z "${REMOTE_PORT}" ]]; then
  export REMOTE_PORT="22"
fi
if [[ -z "${REMOTE_USER}" ]]; then
  echo "Input remote_user is required!"
  exit 1
fi
if [ -z "$REMOTE_PRIVATE_KEY" ] && [ -z "$REMOTE_PRIVATE_KEY_FILE" ]; then
  echo "Error: No Private Key provided. You must set either 'remote_private_key' or 'remote_private_key_file'."
  exit 1
fi

if [ -n "$REMOTE_PRIVATE_KEY_FILE" ] && [ ! -f "$REMOTE_PRIVATE_KEY_FILE" ]; then
  echo "Error: Private key file not found at path: $REMOTE_PRIVATE_KEY_FILE"
  exit 1
fi

if [ "$WITH_CERT" = "true" ] || [ -n "$WITH_CERT" ] && [ "$WITH_CERT" != "false" ]; then
  if [ -z "$REMOTE_PRIVATE_KEY_CERT" ] && [ -z "$REMOTE_PRIVATE_KEY_CERT_FILE" ]; then
    echo "Error: Certificate authentication requested (with_cert=true), but no certificate provided."
    exit 1
  fi

  if [ -n "$REMOTE_PRIVATE_KEY_CERT_FILE" ] && [ ! -f "$REMOTE_PRIVATE_KEY_CERT_FILE" ]; then
    echo "Error: Certificate file not found at path: $REMOTE_PRIVATE_KEY_CERT_FILE"
    exit 1
  fi
fi

# CHECK STACK VARIABLES
if [[ -z "${STACK_FILE}" ]]; then
  echo "Input stack_file is required!"
  exit 1
else
  old_IFS=$IFS
  IFS=','
  echo "Stack files: ${STACK_FILE}"
  for file in ${STACK_FILE}; do
    clean_file=$(echo "$file" | xargs)
    if [ ! -f "${clean_file}" ]; then
      echo "${clean_file} does not exist."
      exit 1
    fi
  done
  IFS=$old_IFS
fi

if [[ -z "${STACK_NAME}" ]]; then
  echo "Input stack_name is required!"
  exit 1
fi


# CONFIGURE SSH CLIENT
if configure_ssh > $OUT 2>&1; then
  echo "SSH client: Configured"
else
  echo "SSH client: Configuration failed"
  exit 1
fi

if configure_ssh_key > $OUT 2>&1; then
  echo "SSH client: Added private key"
else
  echo "SSH client: Private key failed"
  exit 1
fi

if configure_ssh_host > $OUT 2>&1; then
  echo "SSH remote: Keys added to ${KNOWN_HOSTS}"
else
  echo "SSH remote: Server ${REMOTE_HOST} on port ${REMOTE_PORT} not available"
  exit 1
fi

if connect_ssh > $OUT; then
  echo "SSH connect: Success"
else
  echo "SSH connect: Failed to connect to remote server"
  exit 1
fi

export DOCKER_HOST="ssh://${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PORT}"

if deploy > $OUT; then
  echo "Deploy: Updated services"
else
  echo "Deploy: Failed to deploy ${STACK_NAME} from file ${STACK_FILE}"
  exit 1
fi

if check_deploy; then
  echo "Deploy: Completed"
else
  echo "Deploy: Failed"
  exit 1
fi
