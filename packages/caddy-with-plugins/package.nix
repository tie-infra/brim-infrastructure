{
  lib,
  fetchFromGitHub,
  buildGo126Module,
}:
let
  version = "2.11.4";
in
buildGo126Module {
  pname = "caddy";
  inherit version;
  src = ./caddy;

  vendorHash = "sha256-Lt43gRNb58Zmav7FJcmY/8X1dkEaKmPYvwn/8NvAQe8=";

  dist = fetchFromGitHub {
    owner = "caddyserver";
    repo = "dist";
    tag = "v${version}";
    hash = "sha256-oRQfQH1GKjAjVMj+dZo1f1+HOaOdJIyEfod0iGLYcc8=";
  };

  postInstall = ''
    install -Dm644 -t "$out/lib/systemd/system" -- \
      "$dist/init/caddy.service" \
      "$dist/init/caddy-api.service"
    substituteInPlace "$out/lib/systemd/system/caddy.service" \
      --replace-fail "/usr/bin/caddy" "$out/bin/caddy"
    substituteInPlace "$out/lib/systemd/system/caddy-api.service" \
      --replace-fail "/usr/bin/caddy" "$out/bin/caddy"
  '';

  ldflags = [
    "-s"
    "-w"
    "-X=github.com/caddyserver/caddy/v2.CustomVersion=${version}"
  ];

  tags = [
    "nobadger"
    "nomysql"
    "nopgx"
  ];

  meta = {
    homepage = "https://caddyserver.com";
    description = "Fast and extensible multi-platform HTTP/1-2-3 web server with automatic HTTPS";
    license = lib.licenses.asl20;
    mainProgram = "caddy";
  };
}
