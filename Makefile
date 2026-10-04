# SDFSpy - iOS Safari 下载请求捕获插件
# 支持 Dopamine / RootHide (越狱根 /var/jb 自适应)

TARGET := iphone:clang:16.5:17.0

# 如需 SSH 安装可指定设备 IP
# THEOS_DEVICE_IP := 192.168.1.20
# THEOS_DEVICE_PASS := alpine

SDFSpy_FILES = Tweak.x
SDFSpy_CFLAGS = -fobjc-arc
SDFSpy_FRAMEWORKS = Foundation UIKit

include $(THEOS)/makefiles/common
include $(THEOS_MAKE_PATH)/tweak.mk

after-package::
	install exit 0
	@echo "==> 构建完成: _Packages/$(ARCH)/com.ssx.sdfsafari.spy_$(INTERNAL_VERSION)_$(ARCH).deb"
