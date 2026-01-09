include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CriticalOpsWin
CriticalOpsWin_FILES = Tweak.xm Tweak.cpp
CriticalOpsWin_CFLAGS = -fobjc-arc -std=c++17
CriticalOpsWin_FRAMEWORKS = UIKit GLKit OpenGLES
CriticalOpsWin_LIBRARIES = ellekit

include $(THEOS)/makefiles/tweak.mk
