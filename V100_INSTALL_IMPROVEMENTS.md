 # sglang-sxm2 V100 安装改进方案

 本次在 4× V100-SXM2 / CUDA 12.8 / Ubuntu 22.04 / Python 3.12 环境下部署 `sglang-sxm2` 时踩过的坑及对应修复。

 ## 踩坑清单

 ### 1. GitHub 克隆需要代理
 **现象**：国内直接 `git clone` 极慢或失败。  
 **解决**：给 git 临时加上 http/https 代理。

 ### 2. Conda 官方 Channel 要求接受 TOS
 **现象**：
 ```text
 CondaToSNonInteractiveError: Terms of Service have not been accepted
 ```
 **解决**：
 ```bash
 conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main
 conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r
 ```

 ### 3. TurboMind sparse checkout 缺少头文件
 **现象**：编译 `sglang_sm70_turbomind` 时报错：
 ```text
 fatal error: ../../../../../../sm70_tile_runtime_signal.cuh: No such file or directory
 fatal error: custom_all_reduce.cuh: No such file or directory
 fatal error: cub_helpers.h: No such file or directory
 ```
 **根因**：`scripts/install_v100.sh` 用 sparse checkout 只拉取：
 ```bash
 LICENSE csrc/core csrc/sm70_turbomind csrc/moe
 ```
 但源码里存在跨目录 include，导致 `csrc/` 下多个 `.cuh/.cu` 文件缺失。  
 **解决**：改为拉取整个 `csrc/` 目录。

 ### 4. CMake 版本过低
 **现象**：
 ```text
 Could not find CMake with version >=3.26
 ```
 **根因**：Ubuntu apt 默认 cmake 为 3.22.1，而 `python/sglang/kernels/aot` 的构建需要 >=3.26。  
 **解决**：在 conda 环境中用 pip 安装新版 cmake。

 ### 5. Marlin bf16 compat patch 与 CUDA 12.8 冲突
 **现象**：编译 marlin_v100 时报错：
 ```text
 error: function "__bfloat1622float2" has already been defined
 ```
 **根因**：CUDA 12.8 的 `cuda_bf16.hpp` 已为 sm_70 提供这些 bf16 向量内建函数，`marlin-v100-sm70.patch` 又定义一遍，造成重复定义。  
 **解决**：CUDA 12.8+ 时跳过 `marlin-v100-sm70.patch`（即 `MARLIN_V100_SKIP_BF16_COMPAT=1`）。

 ### 6. 缺少 OpenSSL 开发头文件
 **现象**：服务运行后，首次请求触发 JIT 编译 `hicache_hash_cpp` 时失败：
 ```text
 fatal error: openssl/sha.h: No such file or directory
 ```
 **根因**：系统缺少 `libssl-dev`。  
 **解决**：`sudo apt install -y libssl-dev`。

 ### 7. 重启后未激活 conda 环境
 **现象**：重启后运行 serve 脚本报错：
 ```text
 ModuleNotFoundError: No module named 'numpy'
 ```
 **解决**：每次新终端都先 `conda activate sglang-v100`。

 ### 8. 主机内存不足
 **现象**：
 ```text
 ValueError: Not enough host memory available. Requesting 6.64 GB but only have 2.38 GB free.
 ```
 **根因**： hierarchical cache 需要大量主机内存。  
 **解决**：
 - GLM-5.3-Flash 建议主机空闲内存 ≥ 32 GB（运行时约 23 GB）。
 - Qwen3.8-Flash-Next 建议主机内存 ≥ 160 GB（运行时约 134 GB）。
 - DeepSeek-V4.1-Flash 建议主机内存 ≥ 300 GB。

 ---

 ## 代码改进点

 ### A. `scripts/install_v100.sh`
 1. sparse checkout 路径改为 `LICENSE csrc/`，避免缺头文件。
 2. apt 安装列表增加 `libssl-dev`。
 3. 编译 sglang-kernel 前检查 cmake 版本，低于 3.26 则自动用 pip 升级。

 ### B. `scripts/setup_v100_marlin.sh`
 1. 根据 `torch.version.cuda` 自动判断：CUDA >= 12.8 时跳过 `marlin-v100-sm70.patch`。
 2. 保留 `MARLIN_V100_SKIP_BF16_COMPAT` 环境变量，允许用户手动覆盖。

 ### C. 文档
 README / `docs/v100/INSTALL.md` 增加：
 - 国内代理示例
 - Conda TOS 接受命令
 - 重启后激活环境提示
 - 各模型内存需求速查

 ---

 ## 验证结果

 应用本方案后，4× V100 上成功启动 Qwen3.8-Flash-Next-NVFP4（262k context）：

 ```text
 [2026-10-12 09:53:38] INFO:     Uvicorn running on http://0.0.0.0:11435
 [2026-10-12 09:53:45] The server is fired up and ready to roll!
 ```

 API 测试返回正常：

 ```json
 {"choices":[{"message":{"content":"\n\nHello! How can I help you today?"}}]}
 ```
