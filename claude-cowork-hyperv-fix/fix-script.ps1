<#
.SYNOPSIS
    Claude Desktop Cowork Workspace - Hyper-V 虚拟化一键修复脚本
.DESCRIPTION
    自动检测并修复 Claude cowork workspace 所需的虚拟化环境问题。
    包括：VID 驱动状态检查、vmcompute 服务启动、VM bundle 清理等。
.NOTES
    必须以管理员身份运行！
    版本: 1.0
#>

#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"
$script:fixCount = 0
$script:issueCount = 0

function Write-Banner {
    Clear-Host
    Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  Claude Cowork - Hyper-V 虚拟化修复工具 v1.0    ║" -ForegroundColor Cyan
    Write-Host "╠══════════════════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host "║  请确保以管理员身份运行！                       ║" -ForegroundColor Yellow
    Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Step {
    param([string]$Message)
    Write-Host "`n[步骤] $Message" -ForegroundColor Yellow
}

function Write-Ok {
    param([string]$Message)
    Write-Host "  ✓ $Message" -ForegroundColor Green
    $script:fixCount++
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  ⚠ $Message" -ForegroundColor Magenta
}

function Write-Fail {
    param([string]$Message)
    Write-Host "  ✗ $Message" -ForegroundColor Red
    $script:issueCount++
}

# ============================================================
# 步骤 1: 检查系统信息
# ============================================================
function Step1-CheckSystem {
    Write-Step "1/5 检查系统信息"

    $os = Get-CimInstance Win32_OperatingSystem
    Write-Host "  系统版本: $($os.Caption) Build $($os.Version)" -ForegroundColor Gray

    $cpu = Get-CimInstance Win32_Processor
    Write-Host "  CPU: $($cpu.Name)" -ForegroundColor Gray
    if ($cpu.VirtualizationFirmwareEnabled) {
        Write-Ok "BIOS 虚拟化 (SVM/VT-x) 已启用"
    } else {
        Write-Fail "BIOS 虚拟化未启用！请进入 BIOS 开启 SVM（AMD）或 VT-x（Intel）"
    }

    $bios = Get-CimInstance Win32_BIOS
    Write-Host "  BIOS 版本: $($bios.SMBIOSBIOSVersion) ($($bios.ReleaseDate))" -ForegroundColor Gray
}

# ============================================================
# 步骤 2: 检查 BCD 配置
# ============================================================
function Step2-CheckBCD {
    Write-Step "2/5 检查 Hypervisor 启动配置"

    $bcd = bcdedit /enum {current} | Select-String "hypervisorlaunchtype"
    if ($bcd) {
        $value = ($bcd -split '\s+')[-1]
        if ($value -in @('Auto', 'On')) {
            Write-Ok "Hypervisor 启动类型: $value"
        } else {
            Write-Warn "Hypervisor 启动类型: $value，尝试设为 Auto..."
            bcdedit /set hypervisorlaunchtype auto
            Write-Ok "已设置为 Auto（重启后生效）"
        }
    } else {
        Write-Warn "未找到 hypervisorlaunchtype 配置，正在设置..."
        bcdedit /set hypervisorlaunchtype auto
        Write-Ok "已设置为 Auto（重启后生效）"
    }
}

# ============================================================
# 步骤 3: 检查并修复 VID 驱动（核心修复！）
# ============================================================
function Step3-CheckVIDDriver {
    Write-Step "3/5 检查 Hyper-V VID 驱动状态（核心检查项）"

    $vidDriver = Get-PnpDevice | Where-Object {
        $_.FriendlyName -like '*Hyper-V*虚拟化基础结构*' -or
        $_.FriendlyName -like '*Hyper-V*Virtualization Infrastructure*' -or
        $_.Class -eq 'System' -and $_.FriendlyName -like '*Hyper-V*'
    }

    if (-not $vidDriver) {
        Write-Warn "VID 驱动未找到，尝试通过添加过时硬件安装..."
        Write-Fail "无法自动安装 VID 驱动，请手动操作："
        Write-Host "    设备管理器 → 操作 → 添加过时硬件 → 手动选择" -ForegroundColor Yellow
        Write-Host "    → 系统设备 → Microsoft → Microsoft Hyper-V Virtualization Infrastructure Driver" -ForegroundColor Yellow
        return
    }

    foreach ($driver in $vidDriver) {
        Write-Host "  驱动名称: $($driver.FriendlyName)" -ForegroundColor Gray
        Write-Host "  当前状态: $($driver.Status)" -ForegroundColor Gray

        if ($driver.Status -eq 'OK') {
            Write-Ok "VID 驱动状态正常"
        } elseif ($driver.Status -eq 'Error' -or $driver.Status -eq 'Unknown') {
            Write-Warn "VID 驱动异常，尝试启用..."

            $instanceId = $driver.InstanceId
            $enableResult = Enable-PnpDevice -InstanceId $instanceId -Confirm:$false -ErrorAction SilentlyContinue

            if ($?) {
                Start-Sleep 2
                $checkAgain = Get-PnpDevice -InstanceId $instanceId
                if ($checkAgain.Status -eq 'OK') {
                    Write-Ok "VID 驱动已成功启用！"
                } else {
                    Write-Fail "VID 驱动启用失败（状态: $($checkAgain.Status)）"
                    Write-Host "    请手动操作: 设备管理器 → 系统设备 → 右键启用" -ForegroundColor Yellow
                }
            } else {
                Write-Fail "VID 驱动启用失败，请手动操作"
                Write-Host "    设备管理器 → 系统设备 → 找到带黄色警告的 Hyper-V 驱动 → 右键启用" -ForegroundColor Yellow
            }
        }
    }
}

# ============================================================
# 步骤 4: 检查并修复 vmcompute 服务
# ============================================================
function Step4-CheckVmcompute {
    Write-Step "4/5 检查 vmcompute 服务"

    $service = Get-Service vmcompute -ErrorAction SilentlyContinue

    if (-not $service) {
        Write-Fail "vmcompute 服务不存在！请确保 Hyper-V 功能已安装"
        return
    }

    Write-Host "  服务状态: $($service.Status)" -ForegroundColor Gray
    Write-Host "  启动类型: $($service.StartType)" -ForegroundColor Gray

    if ($service.StartType -ne 'Automatic') {
        Write-Warn "启动类型不是 Automatic，正在修改..."
        sc config vmcompute start= auto | Out-Null
        Write-Ok "已修改为自动启动"
    }

    if ($service.Status -ne 'Running') {
        Write-Warn "服务未运行，尝试启动..."
        sc start vmcompute | Out-Null
        Start-Sleep 3

        $service = Get-Service vmcompute
        if ($service.Status -eq 'Running') {
            Write-Ok "vmcompute 服务已成功启动"
        } else {
            Write-Fail "vmcompute 服务无法启动（状态: $($service.Status)）"
            Write-Host "    可以尝试重启电脑后再运行此脚本" -ForegroundColor Yellow
        }
    } else {
        Write-Ok "vmcompute 服务已在运行"
    }

    $vmms = Get-Service vmms -ErrorAction SilentlyContinue
    if ($vmms -and $vmms.Status -eq 'Running') {
        Write-Ok "vmms 服务运行正常"
    } elseif ($vmms) {
        Write-Warn "vmms 服务未运行，尝试启动..."
        sc start vmms | Out-Null
    }
}

# ============================================================
# 步骤 5: 检查 VM bundle 状态
# ============================================================
function Step5-CheckVMBundle {
    Write-Step "5/5 检查 Claude VM bundle 状态"

    $bundlePath = "$env:LOCALAPPDATA\Claude-3p\vm_bundles\claudevm.bundle"
    $logPath = "$env:LOCALAPPDATA\Claude-3p\logs\cowork_vm_node.log"

    if (Test-Path $bundlePath) {
        Write-Host "  VM Bundle 目录存在" -ForegroundColor Gray

        $sessionDisk = Join-Path $bundlePath "sessiondata.vhdx"
        $rootDisk = Join-Path $bundlePath "rootfs.vhdx"

        if ((Test-Path $sessionDisk) -and (Test-Path $rootDisk)) {
            Write-Ok "VM 文件完整"
        } else {
            Write-Warn "部分 VM 文件缺失，Claude 会自动重新下载"
        }

        if (Test-Path $logPath) {
            $hcsError = Select-String -Path $logPath -Pattern "0x80370102|HYPERVISOR_VIRT_DISABLED|0x80070570" -SimpleMatch | Select-Object -Last 1
            if ($hcsError) {
                Write-Warn "日志中存在 VM 启动错误"
                Write-Host "    最后错误: $($hcsError.Line.Substring(0, [Math]::Min($hcsError.Line.Length, 120)))" -ForegroundColor Gray

                $diskError = Select-String -Path $logPath -Pattern "sessiondata.vhdx.*损坏|损坏.*sessiondata.vhdx" -SimpleMatch
                if ($diskError) {
                    Write-Warn "检测到 sessiondata.vhdx 损坏，建议清理重建"
                    $confirm = Read-Host "  是否删除损坏的 VM bundle 并重新下载？(y/n)"
                    if ($confirm -eq 'y') {
                        try {
                            Remove-Item -Path $bundlePath -Recurse -Force
                            Write-Ok "VM bundle 已删除，下次启动 Claude 时会自动重建"
                        } catch {
                            Write-Fail "删除失败: $_"
                            Write-Host "  请手动删除: $bundlePath" -ForegroundColor Yellow
                        }
                    }
                }
            } else {
                Write-Ok "日志中未发现 VM 启动错误"
            }
        }
    } else {
        Write-Warn "VM Bundle 目录不存在（Claude 尚未创建，或已被清理）"
        Write-Host "  启动 Claude 并点击 Workspace 后会自动创建" -ForegroundColor Gray
    }
}

# ============================================================
# 汇总报告
# ============================================================
function Show-Summary {
    Write-Host "`n╔══════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║                   修复报告                       ║" -ForegroundColor Cyan
    Write-Host "╠══════════════════════════════════════════════════╣" -ForegroundColor Cyan

    if ($script:issueCount -eq 0) {
        Write-Host "║  所有检查项均正常 ✓                            ║" -ForegroundColor Green
        Write-Host "║  如果 cowork 仍然无法使用，请尝试重启 Claude   ║" -ForegroundColor Green
    } else {
        Write-Host "║  发现 $($script:issueCount) 个问题，$($script:fixCount) 项已修复        ║" -ForegroundColor Yellow
        Write-Host "║  请根据上述提示手动处理未解决的问题             ║" -ForegroundColor Yellow
    }

    Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Cyan

    Write-Host "`n后续步骤:" -ForegroundColor Cyan
    Write-Host "  1. 如果修改了 BCD 配置或 BIOS，请重启电脑" -ForegroundColor Gray
    Write-Host "  2. 打开 Claude Desktop，点击 Workspace/Cowork" -ForegroundColor Gray
    Write-Host "  3. Claude 会自动下载 VM 文件并初始化" -ForegroundColor Gray
    Write-Host "  4. 如果仍然失败，查看日志: $env:LOCALAPPDATA\Claude-3p\logs\cowork_vm_node.log" -ForegroundColor Gray
}

# ============================================================
# 主流程
# ============================================================
try {
    Write-Banner

    if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
        Write-Fail "此脚本需要管理员权限！"
        Write-Host "  请右键点击 PowerShell → 以管理员身份运行" -ForegroundColor Yellow
        Read-Host "`n按 Enter 键退出"
        exit 1
    }

    Write-Warn "正在检查虚拟化环境，请稍候..."

    Step1-CheckSystem
    Step2-CheckBCD
    Step3-CheckVIDDriver
    Step4-CheckVmcompute
    Step5-CheckVMBundle

    Show-Summary

    Write-Host "`n按 Enter 键退出..."
    Read-Host
}
catch {
    Write-Host "`n脚本执行出错: $_" -ForegroundColor Red
    Write-Host "按 Enter 键退出..."
    Read-Host
    exit 1
}
