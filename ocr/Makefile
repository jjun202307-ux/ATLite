THEOS_PACKAGE_SCHEME = roothide
TARGET := iphone:latest:14.0
ARCHS = arm64 arm64e
include $(THEOS)/makefiles/common.mk
TOOL_NAME = ATLOCRWorker
ATLOCRWorker_FILES = main.m
ATLOCRWorker_FRAMEWORKS = Foundation CoreGraphics ImageIO Vision
ATLOCRWorker_CFLAGS = -fobjc-arc
ATLOCRWorker_INSTALL_PATH = /Applications/ATLite.app
ATLOCRWorker_CODESIGN_FLAGS = -S$(CURDIR)/entitlements.plist
include $(THEOS_MAKE_PATH)/tool.mk
