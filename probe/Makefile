THEOS_PACKAGE_SCHEME = roothide
TARGET := iphone:latest:14.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TOOL_NAME = ATLiteProbe

ATLiteProbe_FILES = main.m
ATLiteProbe_FRAMEWORKS = Foundation CoreFoundation
ATLiteProbe_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
# 实证（已读 theos makefiles/instance/tool.mk）：
#   LOCAL_INSTALL_PATH = $(strip $(<INSTANCE>_INSTALL_PATH))，缺省才回落到 /usr/bin。
# 必须装进 app bundle：iOS 只允许 exec /var/containers/Bundle/ 内的二进制，
# 而 roothide 的 jbroot 正是 /var/containers/Bundle/Application/.jbroot-<hex>。
ATLiteProbe_INSTALL_PATH = /Applications/ATLite.app
ATLiteProbe_CODESIGN_FLAGS = -S$(CURDIR)/entitlements.plist

include $(THEOS_MAKE_PATH)/tool.mk
