#!/usr/bin/env bash

# This is technically redundant, since all consumers of this lib will have enabled these,
# however, it helps Shellcheck realise the options under which these functions will run.
set -euo pipefail

PIPENV_VERSION=$(utils::get_requirement_version 'pipenv')

# TODO: Either enable or remove these.
# export CLINT_FORCE_COLOR=1
# export PIPENV_FORCE_COLOR=1

function pipenv::install_pipenv() {
	meta_set "pipenv_version" "${PIPENV_VERSION}"

	output::step "Installing Pipenv ${PIPENV_VERSION}"

	# TODO: Install Pipenv into a venv so it isn't leaked into the app environment.
	# TODO: Skip installing Pipenv if its version hasn't changed (once it's installed into a venv).
	# TODO: Explore viability of making Pipenv only be available during the build, to reduce slug size.

	# shellcheck disable=SC2310 # This function is invoked in an 'if' condition so set -e will be disabled.
	if ! {
		pip \
			install \
			--disable-pip-version-check \
			--no-cache-dir \
			--no-input \
			--quiet \
			"pipenv==${PIPENV_VERSION}" \
			|& output::indent
	}; then
		output::error <<-EOF
			Error: Unable to install Pipenv.

			In some cases, this happens due to a temporary issue with
			the network connection or Python Package Index (PyPI).

			Try building again to see if the error resolves itself.

			If that doesn't help, check the status of PyPI here:
			https://status.python.org
		EOF
		meta_set "failure_reason" "install-package-manager::pipenv"
		exit 1
	fi
}

# Previous versions of the buildpack used to cache the checksum of the lockfile to allow
# for skipping pipenv install if the lockfile was unchanged. However, this is not always safe
# to do (the lockfile can refer to dependencies that can change independently of the lockfile,
# for example, when using a local non-editable file dependency), so we no longer ever skip
# install, and instead defer to Pipenv to determine whether install is actually a no-op.
function pipenv::install_dependencies() {
	# Make select pip config vars set on the Heroku app available to the pip used by Pipenv.
	# TODO: Expose all config vars (after suitable checks are added for unsafe env vars).
	#
	# PIP_EXTRA_INDEX_URL allows for an alternate pypi URL to be used.
	# shellcheck disable=SC2154 # TODO: Env var is referenced but not assigned.
	if [[ -r "${ENV_DIR}/PIP_EXTRA_INDEX_URL" ]]; then
		PIP_EXTRA_INDEX_URL="$(cat "${ENV_DIR}/PIP_EXTRA_INDEX_URL")"
		export PIP_EXTRA_INDEX_URL
	fi

	# Note: We can't use `pipenv sync` since it doesn't validate that the lockfile is up to date.
	local pipenv_install_command=(
		pipenv
		install
		--deploy
	)

	# Install test dependencies too when the buildpack is invoked via `bin/test-compile` on Heroku CI.
	if [[ -v INSTALL_TEST ]]; then
		pipenv_install_command+=(--dev)
	fi

	# We only display the most relevant command args here, to improve the signal to noise ratio.
	output::step "Installing dependencies using '${pipenv_install_command[*]}'"

	# shellcheck disable=SC2310 # This function is invoked in an 'if' condition so set -e will be disabled.
	if ! {
		"${pipenv_install_command[@]}" \
			--extra-pip-args='--src=/app/.heroku/python/src' \
			--system \
			|& tee "${WARNINGS_LOG:?}" \
			|& output::indent
	}; then
		# TODO: Overhaul warnings and combine them with error handling.
		show-warnings

		output::error <<-EOF
			Error: Unable to install dependencies using Pipenv.

			See the log output above for more information.
		EOF
		meta_set "failure_reason" "install-dependencies::pipenv"
		exit 1
	fi
}
