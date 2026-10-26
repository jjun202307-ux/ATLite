THEOS_PACKAGE_SCHEME = roothide
TARGET := iphone:latest:14.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ATLiteTweak

ATLiteTweak_FILES = ../shared/ATLEmailJob.m Tweak.xm $(wildcard lib/lua53/*.c)
ATLiteTweak_FRAMEWORKS = UIKit Foundation CoreFoundation CoreGraphics ImageIO QuartzCore Vision
ATLiteTweak_CFLAGS = -fobjc-arc -Ilib/lua53 -Wno-deprecated-declarations -Wno-error=string-plus-int

include $(THEOS_MAKE_PATH)/tweak.mk
