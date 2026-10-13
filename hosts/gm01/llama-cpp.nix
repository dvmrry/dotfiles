# llama.cpp for gm01: nixpkgs' package moved to a newer release (Qwen3.8 MTP
# needs it), CUDA kernels for the 4070 Ti Super (Ada, sm_89) only, and
# flash-attention kernels for every KV-cache type. The CPU backend already
# ships per-ISA variants (incl. Zen 4 / AVX-512) chosen at runtime.
{ lib, llama-cpp, fetchFromGitHub }:
(llama-cpp.override { cudaSupport = true; }).overrideAttrs (final: prev: {
  version = "11552";
  src = fetchFromGitHub {
    owner = "ggml-org";
    repo = "llama.cpp";
    tag = "b${final.version}";
    hash = "sha256-0XCaTntMFsDc0yy/q6URst+rUh4BnpwBDPX5BIoZ55I=";
    leaveDotGit = true;
    postFetch = ''
      git -C "$out" rev-parse --short HEAD > $out/COMMIT
      find "$out" -name .git -print0 | xargs -0 rm -rf
    '';
  };
  npmDepsHash = "sha256-hqYzdp1FwPhYkBP278fQXgY9NCKB6Q3P6Gko7BfP0m0=";
  cmakeFlags = prev.cmakeFlags ++ [
    (lib.cmakeFeature "CMAKE_CUDA_ARCHITECTURES" "89")
    (lib.cmakeBool "GGML_CUDA_FA_ALL_QUANTS" true)
  ];
})
