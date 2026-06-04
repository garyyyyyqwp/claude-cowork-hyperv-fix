# Claude Desktop Cowork Workspace 虚拟化故障排查与修复

> **完整复原一次从底层 BIOS 到应用层的 Windows Hyper-V/HCS 虚拟化问题排查过程**

---

## 问题概述

| 项目 | 详情 |
|---|---|
| **设备** | 联想拯救者 R7000P 2023 (AMD Ryzen 7 7840H + RTX 4060) |
| **系统** | Windows 11 专业版 25H2 Build 26200.8037 |
| **BIOS** | M3CN32WW → **M3CN49WW**（更新后修复） |
| **目标软件** | Claude Desktop — Cowork Workspace 功能 |
| **核心错误** | `HRESULT 0x80370102` / `HYPERVISOR_VIRT_DISABLED` / `HCS_E_HYPERV_NOT_INSTALLED` |

### 现象

Claude Desktop 启动 cowork workspace 时报错：

```
VM boot failed: HCS operation failed: failed to create compute system:
HcsWaitForOperationResult failed with HRESULT 0x80370102
{"ErrorMessage":"由于主机上未安装 Hyper-V，因此无法创建系统"}
```

UI 显示：**"Virtualization is not available"**

同时 WSL2 安装 Ubuntu 也报相同错误，说明问题不在 Claude 自身，而在系统底层。

---

## 修复步骤（简化版 — 想直接解决问题看这里）

总共只需要这 5 步：

### 1. 更新 BIOS 到最新版本

这是**最根本**的修复，解决了 AMD SVM 与 Win11 25H2 的兼容性问题。

- 访问 [联想服务官网](https://newsupport.lenovo.com.cn/)
- 输入机器型号，下载最新 BIOS
- 插电源 → 右键管理员运行 → 等待自动重启

### 2. 启用 VID 驱动（关键！）

设备管理器 → 展开 **系统设备** → 找到 **Microsoft Hyper-V 虚拟化基础结构驱动程序** → 右键 → **启用设备**

如果找不到该驱动，用以下方式手动添加：
设备管理器 → 操作 → 添加过时硬件 → 手动选择 → 系统设备 → Microsoft → Microsoft Hyper-V Virtualization Infrastructure Driver

### 3. 启动 vmcompute 服务

```cmd
# 管理员 CMD
sc config vmcompute start= auto
sc start vmcompute
```

### 4. 删除损坏的 VM bundle

```cmd
rmdir /s /q "%LOCALAPPDATA%\Claude-3p\vm_bundles\claudevm.bundle"
```

### 5. 重启 Claude，点击 Workspace 即可

---

## 一、故障排查全过程

### 1.1 架构理解

Claude cowork workspace **不依赖 WSL2**，而是使用 Anthropic 自研轻量级 VM，通过 **HCS (Host Compute Service) API** 直接操作 Hyper-V 计算系统。

```
应用层       Claude Desktop (Electron/Node.js)
              ↓
API 层       HCS API (vmcompute.dll)  ← 问题发生层
              ↓
驱动层       VID 驱动（虚拟化基础结构驱动程序）   ← 被禁用
              ↓
内核层       Windows Hypervisor Platform  → VBS 占用中
              ↓
固件层       AMD SVM (BIOS)  ← 旧版本有兼容性 Bug
```

**两条关键路径对比：**

| 路径 | 组件 | Claude cowork 使用的通道 |
|---|---|---|
| **WMI 路径** | `PowerShell New-VM` → vmms | ❌ 不走此路径 |
| **HCS 路径** | `HCS API` → vmcompute → VID | ✅ **Claude 使用的路径** |

这就是为什么 `PowerShell New-VM` 能创建虚拟机，但 Claude cowork 失败了——两条路径对组件的依赖不同。

### 1.2 排查分层框架

问题排查按以下层级逐层验证：

```
[BIOS 层]  SVM 是否开启？
    ↓  ✅ 任务管理器显示"已启用"
[内核层]  Hypervisor 是否加载？
    ↓  ✅ systeminfo 显示"已检测到"
[驱动层]  VID 驱动状态？
    ↓  ❌ 设备管理器 → 故障代码 22（已禁用）
[服务层]  vmcompute 是否运行？
    ↓  ❌ 服务状态为 Stopped
[API 层]  HCS 能否创建计算系统？
    ↓  ❌ 返回 0x80370102
```

### 1.3 关键诊断工具与命令

```powershell
# 检查 BIOS 虚拟化
Get-CimInstance Win32_Processor | Select-Object Name, VirtualizationFirmwareEnabled

# 检查 hypervisor 状态
systeminfo | findstr "虚拟化 Hyper-V"

# 检查 BCD 配置
bcdedit /enum | findstr hypervisor

# 检查 VID 驱动状态（关键！）
Get-PnpDevice | Where-Object { $_.FriendlyName -like '*Hyper-V*' }

# 检查 vmcompute 服务
Get-Service vmcompute, vmms

# 检查注册表（Guest/ComputeService 缺失是典型症状）
reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Virtualization\Guest"

# 查看 Claude 日志
Get-Content "$env:LOCALAPPDATA\Claude-3p\logs\cowork_vm_node.log" -Tail 30

# 测试 Hyper-V 管理层（WMI 路径）
New-VM -Name TestVM -NoVHD -Generation 2
```

### 1.4 问题根因链

```
旧版 BIOS (M3CN32WW, 2023年5月)
    ↓  AMD SVM 与 Win11 25H2 存在兼容性缺陷
BIOS 层面的兼容性问题
    ↓  VBS 错误占用 hypervisor
systeminfo: "已检测到虚拟机监控程序。将不显示 Hyper-V 所需的功能"
    ↓  Hyper-V 将 VID 驱动标记为禁用
设备管理器: 代码 22，驱动被禁用
    ↓  vmcompute 服务无法启动
HCS 检测不到 Hyper-V
    ↓  CreateComputeSystem 失败
Claude cowork → 0x80370102 / HYPERVISOR_VIRT_DISABLED
```

---

## 二、已尝试但无效的方法清单

这些常规修复方法在本案例中全部无效，列出来避免后来者重复试错：

| 方法 | 结果 |
|---|---|
| `bcdedit /set hypervisorlaunchtype auto/on` | ❌ |
| 启动 vds 服务 + 安装 vhdmp 驱动 | ❌ |
| 启用 vdrvroot 设备 | ❌ |
| wsl --install --no-distribution 重装 WSL | ❌ |
| DISM 启用 Containers / HypervisorPlatform | ❌ |
| 禁用 Device Guard / VBS 组策略 | ❌ |
| Windows Update 到最新 | ❌ |
| DISM Hyper-V 完整卸载→重装循环 | ❌ |
| regsvr32 vmcompute.dll 注册 COM | ❌ |
| sfc /scannow + DISM RestoreHealth | ❌ |
| 虚拟机平台/Windows 超级管理员平台 GUI 开关 | ❌ |

---

## 三、修复脚本

项目附带了一键修复脚本 `fix-script.ps1`，可以自动完成步骤 2~4 的操作。

---

## 四、经验教训

### 4.1 分层诊断优于随机尝试

遇到虚拟化问题，按 **BIOS → 内核 → 驱动 → 服务 → API** 的顺序逐层验证，而不是随机尝试网上找到的各种"修复命令"。

### 4.2 区分不同代码路径

同一个功能可能有不同的代码路径实现。在本案例中，`PowerShell New-VM`（WMI 路径）能成功不代表 `Claude cowork`（HCS 路径）也能成功。

### 4.3 "三条假设"策略

当常规方法无效时，考虑三个方向：

1. **组件层假设** — 某个关键组件被禁用/损坏/缺失
2. **兼容性假设** — 固件/驱动版本与系统不兼容
3. **数据层假设** — 缓存/配置文件损坏

本次故障恰好覆盖了全部三种假设。

### 4.4 关注设备管理器

设备管理器是发现驱动问题的直接入口，但常常被忽略。检查"系统设备"类别下的 Hyper-V 相关驱动状态应该成为标准诊断步骤。

---

## 五、环境信息

| 项目 | 初始值 | 最终值 |
|---|---|---|
| BIOS | M3CN32WW (2023/5/11) | M3CN49WW |
| Windows Build | 26200.8037 | 26200.8037（未更新） |
| WSL 版本 | 2.3.26 | 2.3.26 |
| Claude 版本 | 1.10628.2.0 | 1.10628.2.0 |

---

## 许可

MIT License

---

*如果这个仓库对你有帮助，欢迎 Star！*
