.PHONY: all clean install

MOD_FILES := $(wildcard *.mod *.MOD)
ZIP_FILES := $(MOD_FILES:.mod=.zip) $(MOD_FILES:.MOD=.zip)

all: $(ZIP_FILES)

# Generic rule to convert a .mod file to a .zip using the python script
%.zip: %.mod
	python3 mod2skode.py $< -o $@

%.zip: %.MOD
	python3 mod2skode.py $< -o $@

# Specific target to build and deploy ELYSIUM.MOD directly to skred-web as amiga.zip
install: ELYSIUM.zip
	cp ELYSIUM.zip ../skred-web/amiga.zip
	@echo "Copied ELYSIUM.zip to ../skred-web/amiga.zip"

clean:
	rm -f *.zip
