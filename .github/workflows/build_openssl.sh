#!/bin/bash
set -e
set -x

shlib_sed() {
  # modify the shlib version to a unique one to make sure the dynamic
  # linker doesn't load the system one.
  sed -i "s/^SHLIB_MAJOR=.*/SHLIB_MAJOR=100/" Makefile
  sed -i "s/^SHLIB_MINOR=.*/SHLIB_MINOR=0.0/" Makefile
  sed -i "s/^SHLIB_VERSION_NUMBER=.*/SHLIB_VERSION_NUMBER=100.0.0/" Makefile
}
shlib_sed_3() {
  # OpenSSL 3 changes how it does the shlib versioning
  sed -i "s/^SHLIB_VERSION=.*/SHLIB_VERSION=100/" VERSION.dat
}

if [[ "${TYPE}" == "openssl" ]]; then
  if [[ "${VERSION}" =~ ^[0-9a-f]{40}$ ]]; then
    git clone https://github.com/openssl/openssl
    pushd openssl
    git checkout "${VERSION}"
  else
    curl -O "https://www.openssl.org/source/openssl-${VERSION}.tar.gz"
    tar zxf "openssl-${VERSION}.tar.gz"
    pushd "openssl-${VERSION}"
  fi
  # For OpenSSL 3 we need to call this before config
  if [[ "${VERSION}" =~ ^3. ]] || [[ "${VERSION}" =~ ^[0-9a-f]{40}$ ]]; then
    shlib_sed_3
  fi

  # CONFIG_FLAGS is a global coming from a previous step
  ./config ${CONFIG_FLAGS} -fPIC --prefix="${OSSL_PATH}"

  # For OpenSSL 1 we need to call this after config
  if [[ "${VERSION}" =~ ^1. ]]; then
    shlib_sed
  fi
  make depend
  make -j"$(nproc)"
  # avoid installing the docs (for performance)
  # https://github.com/openssl/openssl/issues/6685#issuecomment-403838728
  make install_sw install_ssldirs
  # For OpenSSL 3.0.0 set up the FIPS config. This does not activate it by
  # default, but allows programmatic activation at runtime
  if [[ "${VERSION}" =~ ^3. && "${CONFIG_FLAGS}" =~ enable-fips ]]; then
      # As of alpha16 we have to install it separately and enable it in the config flags
      make -j"$(nproc)" install_fips
      pushd "${OSSL_PATH}"
      # include the conf file generated as part of install_fips
      sed -i "s:# .include fipsmodule.cnf:.include $(pwd)/ssl/fipsmodule.cnf:" ssl/openssl.cnf
      # uncomment the FIPS section
      sed -i 's:# fips = fips_sect:fips = fips_sect:' ssl/openssl.cnf
      popd
  fi
  popd
elif [[ "${TYPE}" == "libressl" ]]; then
  curl -O "https://ftp.openbsd.org/pub/OpenBSD/LibreSSL/libressl-${VERSION}.tar.gz"
  tar zxf "libressl-${VERSION}.tar.gz"
  pushd "libressl-${VERSION}"
  ./config -Wl -Wl,-Bsymbolic-functions -fPIC shared --prefix="${OSSL_PATH}"
  shlib_sed
  make -j"$(nproc)" install
  popd
elif [[ "${TYPE}" == "boringssl" ]]; then
  git clone https://boringssl.googlesource.com/boringssl
  pushd boringssl
  git checkout "${VERSION}"
  mkdir build
  pushd build
  # Find the default rust target based on what rustc is built for
  cmake .. -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DRUST_BINDINGS="$(rustc -V --verbose | grep 'host: ' | sed 's/host: //')" -DCMAKE_INSTALL_PREFIX="${OSSL_PATH}"
  make -j"$(nproc)"
  make install
  # BoringSSL doesn't have a bin/openssl and we use that to detect success
  touch "${OSSL_PATH}/bin/openssl"
  popd
  popd
fi
