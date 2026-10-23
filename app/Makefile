THEOS_PACKAGE_SCHEME = roothide
TARGET := iphone:latest:14.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = ATLite

ATLite_FILES = Source/main.m Source/ATLAppDelegate.m Source/ATLRootViewController.m Source/ATLWebServer.m
ATLite_FRAMEWORKS = UIKit Foundation CoreFoundation
ATLite_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/application.mk
