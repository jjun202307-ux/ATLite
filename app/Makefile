THEOS_PACKAGE_SCHEME = roothide
TARGET := iphone:latest:14.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = ATLite

ATLite_FILES = Source/main.m Source/ATLAppDelegate.m Source/ATLRootViewController.m Source/ATLWebServer.m Source/ATLPaths.m Source/ATLCommand.m Source/ATLLogViewController.m Source/ATLProbe.m
ATLite_FRAMEWORKS = UIKit Foundation CoreFoundation
ATLite_CFLAGS = -fobjc-arc
# RESEARCH A2/A3：越狱 App 必须带 entitlements（AutoTouch 实证四键），
# Theos 默认 -S 裸假签；实例级 XXX_CODESIGN_FLAGS 覆写（rules.mk L215）。
# ldid 语法为 -S<entitlements路径>，$(CURDIR)=app/ 目录。
ATLite_CODESIGN_FLAGS = -S$(CURDIR)/entitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
