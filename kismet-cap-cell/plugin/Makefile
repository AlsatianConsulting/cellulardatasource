PLUGIN_NAME ?= cell

# Point this to your Kismet source tree
KIS_SRC_DIR ?= /home/user/kismet
KIS_INC_DIR ?= $(KIS_SRC_DIR)

-include $(KIS_SRC_DIR)/Makefile.inc

BLDHOME = .
top_builddir = $(BLDHOME)

INSTALL ?= /usr/bin/install
plugindir ?= $(shell pkg-config --variable=plugindir kismet)

ifeq ("$(plugindir)", "")
	plugindir := "/usr/local/lib/kismet/"
	plugingeneric := "1"
endif

INSTUSR ?= root
INSTGRP ?= root

PLUGINLDFLAGS += -shared -rdynamic
LIBS    += -lstdc++
CFLAGS  += -I/usr/include -I$(KIS_INC_DIR) -g -fPIC
CXXFLAGS += -I/usr/include -I$(KIS_INC_DIR) -g -fPIC

PLUGOBJS = cell_plugin.cc.o
PLUGOUT = cell.so

all: $(PLUGOUT)

$(PLUGOUT): $(PLUGOBJS)
	$(LD) $(PLUGINLDFLAGS) $(PLUGOBJS) -o $(PLUGOUT) $(LIBS)

install: $(PLUGOUT)
ifeq ("$(plugingeneric)", "1")
	@echo "No kismet install found in pkgconfig, assuming /usr/local"
endif
	mkdir -p $(DESTDIR)/$(plugindir)/$(PLUGIN_NAME)
	$(INSTALL) -o $(INSTUSR) -g $(INSTGRP) -m 444 manifest.conf $(DESTDIR)/$(plugindir)/$(PLUGIN_NAME)/manifest.conf
	$(INSTALL) -o $(INSTUSR) -g $(INSTGRP) -m 644 $^ $(DESTDIR)/$(plugindir)/$(PLUGIN_NAME)/$^
	mkdir -p $(DESTDIR)/$(plugindir)/$(PLUGIN_NAME)/httpd/js
ifneq ("$(wildcard httpd/js/*.js)","")
	$(INSTALL) -o $(INSTUSR) -g $(INSTGRP) -m 644 httpd/js/*.js $(DESTDIR)/$(plugindir)/$(PLUGIN_NAME)/httpd/js/
endif

userinstall: $(PLUGOUT)
	mkdir -p ${HOME}/.kismet/plugins/$(PLUGIN_NAME)
	install manifest.conf ${HOME}/.kismet/plugins/$(PLUGIN_NAME)/manifest.conf
	install $^ ${HOME}/.kismet/plugins/$(PLUGIN_NAME)/$^
	mkdir -p ${HOME}/.kismet/plugins/$(PLUGIN_NAME)/httpd/js
ifneq ("$(wildcard httpd/js/*.js)","")
	install httpd/js/*.js ${HOME}/.kismet/plugins/$(PLUGIN_NAME)/httpd/js/
endif

clean:
	@-rm -f *.o
	@-rm -f *.so
	@-rm -f *.d

%.cc.o: %.cc
%.cc.o: %.cc %.cc.d
	$(CXX) $(CXXFLAGS) $(CPPFLAGS) -c $*.cc -o $@

%.cc.d: %.cc
	$(CXX) -MM $(CXXFLAGS) $(CPPFLAGS) $*.cc | sed -e "s/\.o/\.cc.o/" > $*.cc.d

.PRECIOUS: %.cc.d
.SUFFIXES: .cc .o
