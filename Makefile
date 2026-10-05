# SafariGoPeed - iOS Safari 下载请求捕获插件
# 支持 Dopamine / RootHide (越狱根 /var/jb 自适应)

TARGET := iphone:clang::17.0
# 说明：第 3 段是 SDK 版本（留空 = 自动选构建机最新 SDK，如 CI macos-14 的 iPhoneOS17.5），
# 第 4 段是部署目标（最低支持的 iOS 版本）。

# Dopamine / RootHide 均为 rootless 越狱（根在 /var/jb），强制打 rootless 包
# （装到 /var/jb/Library/... ，必须写在 include common.mk 之前）
export THEOS_PACKAGE_SCHEME = rootless

# 如需 SSH 安装可指定设备 IP
# THEOS_DEVICE_IP := 192.168.1.20
# THEOS_DEVICE_PASS := alpine

SafariGoPeed_FILES = Tweak.x
SafariGoPeed_CFLAGS = -fobjc-arc
SafariGoPeed_FRAMEWORKS = Foundation UIKit

# 实例名必须设为 TWEAK_NAME（Theos 靠它生成编译/打包规则），
# 否则 internal-all/internal-stage 无 target，什么都不编译。
TWEAK_NAME = SafariGoPeed

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk

after-package::
	@echo "==> 构建完成: packages/com.ssx.safarigopeed_$(INTERNAL_VERSION)_$(ARCH).deb"
