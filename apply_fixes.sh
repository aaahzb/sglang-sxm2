 #!/usr/bin/env bash
 # Apply sglang-sxm2 V100 install fixes based on real deployment experience.
 # Run this script from the repo root of your forked sglang-sxm2 checkout.
 set -euo pipefail

 cd "$(dirname "$0")"
 REPO_ROOT="$(pwd)"

 if [[ ! -f "$REPO_ROOT/scripts/install_v100.sh" ]] || [[ ! -f "$REPO_ROOT/scripts/setup_v100_marlin.sh" ]]; then
     echo "ERROR: must run this script from the sglang-sxm2 repo root." >&2
     exit 1
 fi

 echo "==> Applying fixes to $REPO_ROOT"

 # 1. Fix TurboMind sparse checkout: fetch whole csrc/ instead of partial paths.
 if grep -q 'LICENSE csrc/core csrc/sm70_turbomind csrc/moe' "$REPO_ROOT/scripts/install_v100.sh"; then
     sed -i 's|LICENSE csrc/core csrc/sm70_turbomind csrc/moe|LICENSE csrc/|' "$REPO_ROOT/scripts/install_v100.sh"
     echo "[OK] fixed TurboMind sparse checkout to pull entire csrc/"
 else
     echo "[SKIP] TurboMind sparse checkout line not found or already fixed"
 fi

 # 2. Add libssl-dev to apt install list if missing.
 python3 <<'PYEOF' - "$REPO_ROOT/scripts/install_v100.sh"
 import sys, re
 path = sys.argv[1]
 with open(path, "r", encoding="utf-8") as f:
     content = f.read()

 if "libssl-dev" in content:
     print("[SKIP] libssl-dev already present")
     sys.exit(0)

 pattern = re.compile(r'(apt(?:-get)?\s+.*?install\s+(?:-[a-zA-Z-]+\s+)*)(.*?)(\\?\n)', re.DOTALL)
 def repl(m):
     prefix = m.group(1)
     pkgs = m.group(2)
     newline = m.group(3)
     for anchor in ("libnuma-dev", "pkg-config", "ninja-build", "build-essential"):
         if anchor in pkgs:
             pkgs = pkgs.replace(anchor, f"{anchor} libssl-dev", 1)
             break
     else:
         pkgs = pkgs.rstrip() + " libssl-dev"
     return prefix + pkgs + newline

 new_content, n = pattern.subn(repl, content)
 if n > 0:
     with open(path, "w", encoding="utf-8") as f:
         f.write(new_content)
     print("[OK] added libssl-dev to apt install line")
 else:
     print("[WARN] could not find apt install line; add libssl-dev manually")
 PYEOF

 # 3. Ensure cmake >= 3.26 before building sglang-kernel.
 python3 <<'PYEOF' - "$REPO_ROOT/scripts/install_v100.sh"
 import sys
 path = sys.argv[1]
 with open(path, "r", encoding="utf-8") as f:
     content = f.read()

 if "install_cmake_if_needed" in content:
     print("[SKIP] cmake check already present")
     sys.exit(0)

 snippet = '''# --- ensure CMake >= 3.26 for sglang-kernel AOT build ---------------------------
 install_cmake_if_needed() {
     local required_major=3 required_minor=26
     local current_version current_major current_minor
     current_version="$(cmake --version 2>/dev/null | head -n1 | awk '{print $3}')"
     if [[ -n "$current_version" ]]; then
         current_major="${current_version%%.*}"
         current_minor="${current_version#*.}"
         current_minor="${current_minor%%.*}"
         if [[ "$current_major" -gt "$required_major" ]] || { [[ "$current_major" -eq "$required_major" ]] && [[ "$current_minor" -ge "$required_minor" ]]; }; then
             return 0
         fi
     fi
     echo "[install_v100] CMake >= 3.26 required, installing via pip"
     python -m pip install --upgrade "cmake>=3.26"
 }
 install_cmake_if_needed
 # ---------------------------------------------------------------------------

 '''
 lines = content.splitlines(keepends=True)
 insert_idx = 0
 for i, line in enumerate(lines):
     insert_idx = i + 1
     if not line.startswith('#') and line.strip():
         break
 new_lines = lines[:insert_idx] + ['\n', snippet] + lines[insert_idx:]
 with open(path, "w", encoding="utf-8") as f:
     f.writelines(new_lines)
 print("[OK] inserted cmake version check at top of install_v100.sh")
 PYEOF

 # 4. Auto-skip marlin-v100-sm70.patch on CUDA 12.8+.
 python3 <<'PYEOF' - "$REPO_ROOT/scripts/setup_v100_marlin.sh"
 import sys
 path = sys.argv[1]
 with open(path, "r", encoding="utf-8") as f:
     content = f.read()

 old = '''if [[ "${MARLIN_V100_SKIP_BF16_COMPAT:-0}" != 1 ]]; then
   SM70_PATCHES+=("$PATCH_DIR/marlin-v100-sm70.patch")
 fi'''
 new = '''if [[ "${MARLIN_V100_SKIP_BF16_COMPAT:-0}" != 1 ]]; then
   # CUDA 12.8+ already provides the bf16 vector intrinsics that this patch
   # shims for older toolkits; applying it on 12.8+ causes redefinition errors.
   if [[ "${CUDA_VER:-}" =~ ^12\\.([8-9]|[0-9]{2}) ]] || [[ "${CUDA_VER:-}" =~ ^1[3-9]\\. ]]; then
     log "CUDA ${CUDA_VER} detected; skipping marlin-v100-sm70.patch (bf16 compat not needed)"
   else
     SM70_PATCHES+=("$PATCH_DIR/marlin-v100-sm70.patch")
   fi
 fi'''
 if old in content:
     content = content.replace(old, new)
     with open(path, "w", encoding="utf-8") as f:
         f.write(content)
     print("[OK] auto-detect CUDA 12.8+ in setup_v100_marlin.sh")
 else:
     print("[SKIP] setup_v100_marlin.sh block pattern not found or already modified")
 PYEOF

 echo
 echo "Fixes applied. Review with: git diff"
 echo "Then commit and push following APPLY_AND_PUSH.md."
