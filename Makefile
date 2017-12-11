host := 127.0.0.1
user := mayur
password := mayur
script := scripts/dump_restore.sh

.PHONY: clean
clean:
	$(info Cleaning up the swap files)
	@rm -rf *.swp *.retry backup

.PHONY: setup
setup:
	ansible-playbook -e "install=true" --flush-cache db-server.yml -u mayur -b --become-user=root -i inventory

.PHONY: purge
purge:
	ansible-playbook  -e "uninstall=true" --flush-cache db-server.yml -u mayur -b --become-user=root -i inventory

#.PHONY: check-db
#check-db:
#	ifndef db
#	  $(error Please specify the database to be backed up !!!!) 
#	endif

backup: $(script) clean 
	$(script) -b -s $(host) -d $(db) -f $@ -u $(user) -p $(password)

restore:
	#we create  a new database on the fly and restore the db there
	$(script) -r -s $(host) -c -d $(db) -f backup -u $(user) -p $(password)

shellcheck:
	-@shellcheck $(script)

test:
	$(info Test case 1: pass unknown option)
	$(script) -b -s $(host) -d $(db) -f $@ -u $(user) -p $(password) -g
	
	$(info Test case 2: pass Incorrect creds)
	$(script) -b -s $(host) -d $(db) -f $@ -u $(user) -p $(password) -g
