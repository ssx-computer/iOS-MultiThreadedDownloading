# SDFSpy - iOS Safari 下载请求捕获插件
# 支持 Dopamine / RootHide (越狱根 /var/jb 自适应)

TARGET := iphone:clang::17.0
# 说明：第 3 段是 SDK 版本（留空 = 自动选构建机最新 SDK，如 CI macos-14 的 iPhoneOS17.5），
# 第 4 段是部署目标（最低支持的 iOS 版本）。

# 如需 SSH 安装可指定设备 IP
# THEOS_DEVICE_IP := 192.168.1.20
# THEOS_DEVICE_PASS := alpine

SDFSpy_FILES = Tweak.x
SDFSpy_CFLAGS = -fobjc-arc
SDFSpy_FRAMEWORKS = Foundation UIKit

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk

after-package::
	@echo "==> 构建完成: _Packages/$(ARCH)/com.ssx.sdfsafari.spy_$(INTERNAL_VERSION)_$(ARCH).deb"
