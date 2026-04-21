#!/usr/bin/env bash
set -euo pipefail # Strict mode: crash on error or unbound variables

BUILD_DIR="/var/tmp/VER-davinci-build"

# These variables are automatically injected by the Nix Scraper CI/CD pipeline
VERSION="20.3.2"
REFERID="263d62f31cbb49e0868005059abcb0c9"

ZIP_NAME="DaVinci_Resolve_Studio_${VERSION}_Linux.zip"

echo "==========================================================="
echo " DaVinci Resolve Studio VER Installer"
echo "==========================================================="
echo "WARNING: This requires ~3.6GB of download bandwidth and "
echo "~12GB of temporary disk space on your root/var drive."
echo ""
echo "Blackmagic Design's ToS requires accurate registration data."
echo "Do you want to manually enter your details to comply with their ToS?"
read -p "[y/N] (Default N - Use anonymized NixOS bypass): " choice

if [[ "$choice" =~ ^[Yy]$ ]]; then
    read -p "First Name: " user_fname
    read -p "Last Name: " user_lname
    read -p "Email: " user_email
    read -p "City: " user_city
    REQJSON="{\"firstname\":\"$user_fname\",\"lastname\":\"$user_lname\",\"email\":\"$user_email\",\"phone\":\"0000000000\",\"country\":\"us\",\"state\":\"New York\",\"city\":\"$user_city\",\"product\":\"DaVinci Resolve Studio\"}"
else
    echo "[*] Proceeding with anonymized defaults (Liability assumed by user)..."
    REQJSON="{\"firstname\":\"NixOS\",\"lastname\":\"Linux\",\"email\":\"someone@nixos.org\",\"phone\":\"+31 71 452 5670\",\"country\":\"nl\",\"state\":\"Province of Utrecht\",\"city\":\"Utrecht\",\"product\":\"DaVinci Resolve Studio\"}"
fi

# Cache sudo credentials upfront so the installation step doesn't hang later
echo "[*] Caching sudo credentials for final installation step..."
sudo -v

# Fetching resolving urls and spoofing like nixpkgs
DOWNLOADSURL="https://www.blackmagicdesign.com/api/support/us/downloads.json"
PRODUCT="DaVinci Resolve Studio"
USERAGENT="User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/77.0.3865.75 Safari/537.36"
SITEURL="https://www.blackmagicdesign.com/api/register/us/download"

echo "[*] Fetching dynamic Download ID from Blackmagic API..."
DOWNLOADID=$(curl --silent --compressed "$DOWNLOADSURL" | jq --raw-output ".downloads[] | .urls.Linux?[]? | select(.downloadTitle | test(\"^$PRODUCT $VERSION( Update)?$\")) | .downloadId")

if [[ -z "$DOWNLOADID" || "$DOWNLOADID" == "null" ]]; then
    echo "ERROR: Failed to fetch DOWNLOADID. Is the version ($VERSION) still available?"
    exit 1
fi

echo "[*] Registering download to fetch token..."
RESOLVEURL=$(curl --silent \
    --header 'Host: www.blackmagicdesign.com' \
    --header 'Accept: application/json, text/plain, */*' \
    --header 'Origin: https://www.blackmagicdesign.com' \
    --header "$USERAGENT" \
    --header 'Content-Type: application/json;charset=UTF-8' \
    --header "Referer: https://www.blackmagicdesign.com/support/download/$REFERID/Linux" \
    --header 'Accept-Encoding: gzip, deflate, br' \
    --header 'Accept-Language: en-US,en;q=0.9' \
    --header 'Authority: www.blackmagicdesign.com' \
    --header 'Cookie: _ga=GA1.2.1849503966.1518103294; _gid=GA1.2.953840595.1518103294' \
    --data-ascii "$REQJSON" \
    --compressed \
    "$SITEURL/$DOWNLOADID")

if [[ "$RESOLVEURL" == *"error"* ]] || [[ -z "$RESOLVEURL" ]]; then
    echo "ERROR: Registration failed. Blackmagic API returned an invalid Resolve URL token."
    echo "$RESOLVEURL"
    exit 1
fi

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "[*] Downloading DaVinci Resolve Studio..."
if [[ ! -f "$ZIP_NAME" ]]; then
    curl --retry 3 --retry-delay 3 \
        --header "Upgrade-Insecure-Requests: 1" \
        --header "$USERAGENT" \
        --header "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8" \
        --header "Accept-Language: en-US,en;q=0.9" \
        --compressed \
        --progress-bar \
        -o "$ZIP_NAME" \
        "$RESOLVEURL"
else
    echo "[*] Cache hit: $ZIP_NAME already exists in temp dir."
fi

echo "[*] Bootstrapping Void build environment..."
if [[ ! -d "void-packages" ]]; then
    git clone --depth 1 https://github.com/void-linux/void-packages.git
fi
cd void-packages
./xbps-src binary-bootstrap
echo "XBPS_ALLOW_RESTRICTED=yes" >> etc/conf

echo "[*] Injecting dynamic xbps-src template..."
mkdir -p srcpkgs/davinci-resolve-studio
cat << 'EOF' > srcpkgs/davinci-resolve-studio/template
pkgname=davinci-resolve-studio
version=20.3.2
revision=1
short_desc="Professional video editing, color, effects and audio post-processing"
maintainer="Local Build <VER@localhost>"
license="custom:Proprietary"
homepage="https://www.blackmagicdesign.com/products/davinciresolve"
depends="libGLU glib alsa-lib ocl-icd fontconfig freetype nspr xcb-util-keysyms xcb-util-image xcb-util-renderutil xcb-util-wm dbus udev python3 bash"
makedepends="unzip"
restricted=yes
nostrip=yes

do_extract() {
    unzip ${XBPS_SRCDIR}/${pkgname}-${version}/DaVinci_Resolve_Studio_${version}_Linux.zip -d ${wrksrc}
    local _runfile=$(ls ${wrksrc}/*.run)
    chmod +x "${_runfile}"
    "${_runfile}" --appimage-extract
}

do_install() {
    local _opt="opt/resolve"
    vmkdir ${_opt}
    vcopy squashfs-root/* ${_opt}/

    # Generate the crucial wrapper script
    vmkdir usr/bin
    cat << 'INNEREOF' > ${DESTDIR}/usr/bin/davinci-resolve-studio
#!/bin/sh
export LD_LIBRARY_PATH="/opt/resolve/libs:/usr/lib:/usr/lib32${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export QT_PLUGIN_PATH="/opt/resolve/libs/plugins${QT_PLUGIN_PATH:+:$QT_PLUGIN_PATH}"
exec /opt/resolve/bin/resolve "$@"
INNEREOF
    chmod +x ${DESTDIR}/usr/bin/davinci-resolve-studio

    # Isolate the desktop file name first to avoid vinstall glob errors
    local _deskfile=$(ls squashfs-root/share/applications/*.desktop | head -n 1)
    
    # vinstall <source> <mode> <target_dir> <new_name>
    vmkdir usr/share/applications
    vinstall "${_deskfile}" 644 usr/share/applications davinci-resolve-studio.desktop
    
    # Patch the newly renamed file
    sed -i 's|^Exec=.*|Exec=/usr/bin/davinci-resolve-studio %u|' ${DESTDIR}/usr/share/applications/davinci-resolve-studio.desktop
    
    # Install the icon
    vmkdir usr/share/icons/hicolor/128x128/apps
    vinstall squashfs-root/graphics/DV_Resolve.png 644 usr/share/icons/hicolor/128x128/apps/ davinci-resolve-studio.png
}
EOF

# Synergize template version with dynamic script version
sed -i "s/version=20.3.2/version=$VERSION/" srcpkgs/davinci-resolve-studio/template

# Move zip to hostdir so xbps-src detects it
mkdir -p "hostdir/sources/davinci-resolve-studio-$VERSION/"
mv "../$ZIP_NAME" "hostdir/sources/davinci-resolve-studio-$VERSION/"

echo "[*] Packaging binaries natively into XBPS..."
./xbps-src pkg davinci-resolve-studio

echo "[*] Installing the natively tracked package..."
sudo xbps-install --repository hostdir/binpkgs davinci-resolve-studio

echo "[*] Purging ephemeral build environment..."
# Sanity checked rm -rf strictly verifying variable is not unset or empty
rm -rf "${BUILD_DIR:?Critical Error: BUILD_DIR is unset. Aborting wipe.}"
echo "[*] Installation complete. Void is Entropy."
