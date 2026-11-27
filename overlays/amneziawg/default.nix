final: prev:
let
  # NixOS 26.05 ships AmneziaWG 2.0 (1.0.20260329-2 / 1.0.20260223), whereas
  # our OpenWrt peer (broom) runs AmneziaWG 3.1 (3.1.20261113.02 / 3.1.20260812)
  # with HeaderProtectionKey, timer ranges, RandomTrailers, and DisableCookies.
  # Remove this overlay once the pinned Nixpkgs input provides AWG 3.1.
  overrideAmneziawgModule =
    kprev:
    kprev.amneziawg.overrideAttrs (
      finalAttrs: _: {
        version = "3.1.20261113-02";
        src = final.fetchFromGitHub {
          owner = "amnezia-vpn";
          repo = "amneziawg-linux-kernel-module";
          tag = "v${finalAttrs.version}";
          hash = "sha256-kchxG+8mbXAMxBKo3TZikHuUhJhpNwq5bpPsVKlwsF8=";
        };
        # Upstream 3.1 Makefile no longer carries the literal 1.0.0 placeholder
        # substituted by the NixOS 26.05 derivation's postPatch.
        postPatch = "";
      }
    );
in
{
  amneziawg-tools = prev.amneziawg-tools.overrideAttrs (
    finalAttrs: _: {
      version = "3.1.20260812";
      src = final.fetchFromGitHub {
        owner = "amnezia-vpn";
        repo = "amneziawg-tools";
        tag = "v${finalAttrs.version}";
        hash = "sha256-6GEb41ERhR0Hg3RbSyIHdXPSKaxugoFCmFS5S0UiZso=";
      };
    }
  );

  linuxKernel = prev.linuxKernel // {
    packagesFor =
      kernel:
      (prev.linuxKernel.packagesFor kernel).extend (
        _: kprev: {
          amneziawg = overrideAmneziawgModule kprev;
        }
      );
  };
}
