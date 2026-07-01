#!/bin/sh
set -e

# Get script parent directory path
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

echo "Starting package build..."

# Clean old files
rm -rf build_tmp
rm -f luci-app-apple-cdn-opt_*.ipk

# Create build tree
mkdir -p build_tmp/control
mkdir -p build_tmp/data

# 1. Copy data files
if [ -d "luci-app-apple-cdn-opt/root" ]; then
	cp -R luci-app-apple-cdn-opt/root/* build_tmp/data/
fi
# Grant executable permissions to critical scripts
chmod +x build_tmp/data/etc/init.d/apple_cdn_opt
chmod +x build_tmp/data/usr/share/apple-cdn-opt/apple-cdn-opt.sh

# 2. Copy control files
cp luci-app-apple-cdn-opt/ipkg/control build_tmp/control/control
cp luci-app-apple-cdn-opt/ipkg/conffiles build_tmp/control/conffiles
cp luci-app-apple-cdn-opt/ipkg/postinst build_tmp/control/postinst
cp luci-app-apple-cdn-opt/ipkg/postrm build_tmp/control/postrm
chmod +x build_tmp/control/postinst
chmod +x build_tmp/control/postrm

# 3. Create debian-binary descriptor
echo "2.0" > build_tmp/debian-binary

# 4. Package control.tar.gz
cd build_tmp/control
tar -czf ../control.tar.gz *
cd "$DIR"

# 5. Package data.tar.gz
cd build_tmp/data
tar -czf ../data.tar.gz *
cd "$DIR"

# 6. Package final .ipk (which is control.tar.gz + data.tar.gz + debian-binary)
VERSION=$(grep -i '^Version:' luci-app-apple-cdn-opt/ipkg/control | awk '{print $2}')
[ -z "$VERSION" ] && VERSION="1.0"

# Clean old files first
rm -f luci-app-apple-cdn-opt_*.ipk

cd build_tmp
tar -czf ../luci-app-apple-cdn-opt_${VERSION}_all.ipk debian-binary control.tar.gz data.tar.gz
cd "$DIR"

# Cleanup
rm -rf build_tmp

echo "--------------------------------------------------------"
echo "Build Completed successfully!"
echo "Output file: luci-app-apple-cdn-opt_${VERSION}_all.ipk"
echo "--------------------------------------------------------"
