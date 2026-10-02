#!/usr/bin/env bash
set -euo pipefail

# Run inside the selected vpsAdmin .#api shell, which already enters api/.
: "${VPSADMIN_REPO_ROOT:?enter the selected vpsAdmin API Nix shell}"
if [[ -n ${DATABASE_URL+x} || -e "$VPSADMIN_REPO_ROOT/api/config/database.yml" ]]; then
  echo 'storage-profile specs refuse a configured database' >&2
  exit 1
fi
if [[ $(pwd -P) != "$(realpath "$VPSADMIN_REPO_ROOT/api")" ]]; then
  echo 'storage-profile specs require the selected API shell working directory' >&2
  exit 1
fi
provider_root=$(cd -- "$(dirname -- "$0")/../../.." && pwd -P)
export RACK_ENV=test VPSADMIN_TEST_DB_AUTO=1
# Short private paths avoid the UNIX socket limit in nested Nix environments.
profile_test_tmp=$(mktemp -d /tmp/vp-profile.XXXXXXXX)
chmod 0700 "$profile_test_tmp"
export TMPDIR="$profile_test_tmp"
# RSpec 3.13 custom options replace .rspec, which otherwise preloads
# spec_helper before the provider spec can reject a configured database.
bundle exec rspec --options /dev/null --format documentation "$provider_root/test/vpsadmin_storage_profile_spec.rb" "$@"
