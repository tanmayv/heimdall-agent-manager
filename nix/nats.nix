# Source/version/hash come from the locked nixpkgs libnats-c (Apache-2.0).
# Build only the synchronous client's dependency set; NKey signing uses nats.c's
# built-in implementation, not libsodium. TLS shares curl's OpenSSL provider.
{ pkgs }:
pkgs.stdenv.mkDerivation {
  pname = "heimdall-nats";
  inherit (pkgs.libnats-c) version src;
  # Keep nanosecond place value before nats.c trims trailing fractional zeros.
  patches = [ ./patches/nats-encode-time-utc-leading-zeros.patch ];
  patchFlags = [ "-p1" "--fuzz=0" ];
  nativeBuildInputs = [ pkgs.cmake ];
  buildInputs = [ pkgs.openssl ];
  cmakeFlags = [
    "-DNATS_BUILD_WITH_TLS=ON"
    "-DNATS_BUILD_TLS_FORCE_HOST_VERIFY=ON"
    "-DNATS_BUILD_USE_SODIUM=OFF"
    "-DNATS_BUILD_STREAMING=OFF"
    "-DNATS_BUILD_EXAMPLES=OFF"
    "-DNATS_BUILD_LIB_SHARED=OFF"
    "-DNATS_BUILD_LIB_STATIC=ON"
  ];
  postInstall = ''
    $CC -std=c11 -Wall -Wextra -Werror -I$out/include -c \
      ${../src/lib/nats/adapter.c} -o ham_nats.o
    $AR rcs $out/lib/libham_nats.a ham_nats.o
  '';
  meta.license = pkgs.lib.licenses.asl20;
}
