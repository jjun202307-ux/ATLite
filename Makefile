THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += tweak app

include $(THEOS_MAKE_PATH)/aggregate.mk
