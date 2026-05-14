#!/bin/sh

set -eu

skip_install_env_var="WOORILEE_SKIP_INSTALL"
install_during_build_env_var="WOORILEE_INSTALL_BUILT_INPUT_METHOD"
input_method_install_dir="/Library/Input Methods"

if [ "${WOORILEE_SKIP_INSTALL:-0}" = "1" ]; then
  echo "Skipping input method install because ${skip_install_env_var}=1."
  exit 0
fi

if [ "${WOORILEE_INSTALL_BUILT_INPUT_METHOD:-}" = "0" ]; then
  echo "Skipping input method install because ${install_during_build_env_var}=0."
  exit 0
fi

if [ "${WOORILEE_INSTALL_BUILT_INPUT_METHOD:-0}" != "1" ]; then
  echo "Skipping input method install by default. Set ${install_during_build_env_var}=1 to install into ${input_method_install_dir}."
  exit 0
fi

required_vars="TARGET_BUILD_DIR FULL_PRODUCT_NAME PRODUCT_NAME"
for var_name in $required_vars; do
  eval "var_value=\${$var_name:-}"
  if [ -z "$var_value" ]; then
    echo "Missing Xcode build setting: $var_name" >&2
    exit 1
  fi
done

source_app="${TARGET_BUILD_DIR}/${FULL_PRODUCT_NAME}"
destination_dir="${input_method_install_dir}"
destination_app="${destination_dir}/${FULL_PRODUCT_NAME}"
app_process_name="${PRODUCT_NAME}"

if [ ! -d "$source_app" ]; then
  echo "Built app bundle not found at: $source_app" >&2
  exit 1
fi

install_app() {
  /usr/bin/killall "$app_process_name" >/dev/null 2>&1 || true
  /bin/rm -rf "$destination_app"
  /usr/bin/ditto "$source_app" "$destination_app"
}

if [ -w "$destination_dir" ] && { [ ! -e "$destination_app" ] || [ -w "$destination_app" ]; }; then
  install_app
  exit 0
fi

/usr/bin/osascript - "$app_process_name" "$source_app" "$destination_app" <<'APPLESCRIPT'
on run argv
  set appProcessName to item 1 of argv
  set sourceApp to item 2 of argv
  set destinationApp to item 3 of argv
  set installCommand to "/usr/bin/killall " & quoted form of appProcessName & " >/dev/null 2>&1 || true; " & "/bin/rm -rf " & quoted form of destinationApp & "; " & "/usr/bin/ditto " & quoted form of sourceApp & " " & quoted form of destinationApp
  do shell script installCommand with administrator privileges
end run
APPLESCRIPT
