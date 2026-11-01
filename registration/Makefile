THEOS_PACKAGE_SCHEME = roothide
TARGET := iphone:latest:14.0
ARCHS = arm64 arm64e
include $(THEOS)/makefiles/common.mk
TOOL_NAME = ATLiteRegistration
ATLiteRegistration_FILES = main.m ../shared/ATLRegistrationCLI.m ../shared/ATLRegistrationJob.m ../app/Source/ATLPaths.m
ATLiteRegistration_FRAMEWORKS = Foundation UIKit
ATLiteRegistration_CFLAGS = -fobjc-arc
ATLiteRegistration_INSTALL_PATH = /Applications/ATLite.app
ATLiteRegistration_CODESIGN_FLAGS = -S$(CURDIR)/../probe/entitlements.plist
include $(THEOS_MAKE_PATH)/tool.mk
