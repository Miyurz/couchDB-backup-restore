#!/usr/bin/env bash
#set -euo pipefail

function timeStamp() {
    echo $(date +"%Y-%m-%d %H:%M:%S")
}

function checkPrereqs() {
   ## Check for curl
   curl --version >/dev/null 2>&1 || ( echo -e "\t $(timeStamp) ERROR: Please install curl via apt-get "; exit 1 )

   # Check for tr
   echo | tr -d "" >/dev/null 2>&1 || ( echo -e "\t $(timeStamp) ERROR: Please install 'tr'"; exit 1 )
   
   # chcek for stream editor
   sed=$(which sed >/dev/null);
   if [ $? != 0 ]; then
     echo -e "\t$(timeStamp) ERROR: please install $sed";
     exit 1
   fi
}

#Run the script as is to know how to run the script
if [ "$#" -eq "0" ]; then
   echo -e "\t$(timeStamp) ERROR: Run the script as $0 -h"
   exit 1
fi

checkPrereqs

function usage(){
    echo "script usage: $(basename $0) [-B|-R] -s <COUCHDB_HOST> -d <DB_NAME> -f <BACKUP_FILE> -u <username> -p <password> [-n <port>]"
    echo -e "\t-b   Enable dump backup mode"
    echo -e "\t-r   Enable dump restore mode"
    echo -e "\t-s   Server IP"
    echo -e "\t-d   Database name to backup/restore."
    echo -e "\t-f   File to Backup-to/Restore-from."
    echo -e "\t-n   Provide a port number to connect to. Default port would be assumed as 5984"
    echo -e "\t-u   Username to authenticate against couchDB"
    echo -e "\t-p   Password to authenticate against CouchDB"
    echo -e "\t-a   Restore retry count is set to 3"
    echo -e "\t-c   Create DB on demand, if they are not listed."
    echo -e "\t-q   Run in quiet mode. Suppress output, except for errors and warnings."
    echo -e "\t-z   Compress output file (Backup Only)"
    echo -e "\t-t   Add datetime stamp to output file name (Backup Only)"
    echo -e "\t-h   Show help"
    echo "Example: $0 -B -s 127.0.0.1 -d mydb -f dumpedDB.json -u admin -p password"
    exit 1
}

# Default Args
backup=false
restore=false
port=5984   # Default couchDB port
attempts=3
createDBsOnDemand=false
verboseMode=true
compress=false
timestamp=false

# 1. If OptionString begins with a : (colon), Name will be set to a ? (question mark) character for an unknown option or to a : (colon) character for a missing required option,
#    OPTARG will be set to the option character found, and no output will be written to standard error.

# 2. If a character in OptionString is followed by a : (colon), that option is expected to have an argument. When an option requires an option-argument, the getopts command places      it in the variable OPTARG.

while getopts ":h?b?r?s:d:f:u:p:n?c?" option; do
    case "$option" in
        h) usage
           ;;
        b) backup=true 
           ;;
        r) restore=true 
           ;;
        s) url="$OPTARG" 
	     if [ "$url" = "" ]; then
               echo "ERROR: Missing argument '-s <host>'"
               echo "Run $0 -h"
             fi
           ;;
        d) db_name="$OPTARG" 
	     if [ "$db_name" = "" ]; then
               echo "ERROR: Missing argument '-d <dbName>'"
               echo "Run $0 -h"
             fi
           ;;
        f) file_name="$OPTARG" 
	     if [ "$file_name" = "" ]; then
               echo "... ERROR: Missing argument '-f <FILENAME>'"
               echo "Run $0 -h"
             fi
           ;;
        u) username="${OPTARG}"
           ;;
        p) password="${OPTARG}"
           echo $(timeStamp) password is ${OPTARG}
           ;;
        n) port="${OPTARG}"
           ;;
        c) createDBsOnDemand=true
           ;;
        :) echo -e "\t$(timeStamp) ERROR: You must provide an arg to the Option '-${OPTARG}'"; 
           echo -e "\t$(timeStamp) INFO: Run $0 -h";
           exit 1 
           ;;
        *|\?) echo -e "\t$(timeStamp) ERROR: Unknown option supplied '-${OPTARG}'"; 
              echo -e "\t$(timeStamp) INFO:Run $0 -h";
              exit 1
           ;;
    esac
done

curlSilentOpt=""

# Handle invalid backup/restore states:
if [ $backup = true ] && [ $restore = true ]; then
    echo "ERROR: You cannot backup and recover in one shot"
    echo "Run $0 -h"
elif [ $backup = false ]&&[ $restore = false ]; then
    echo "ERROR: You must specify if you want to backup or restore the dump"
    echo "Run $0 -h"
fi

file_name_orig=$file_name

# Validate Attempts, set to no-retry if zero/invalid.
case $attempts in
    ''|0|*[!0-9]*) echo "... WARN: Retry Attempt value of \"$attempts\" is invalid. Disabling Retry-on-Error."; attempts=1 ;;
    *) true ;;
esac

## Manage the passing of http/https for $url:
# Note; if the user wants to use 'https://' on a non-443 port they must specify it exclusively in the '-H <HOSTNAME>' arg.
if [ ! "`echo $url | grep -c http`" = 1 ]; then
    if [ "$port" == "443" ]; then
        url="https://$url";
    else
        url="http://$url";
    fi
fi

# Manage the addition of port
# If a port isn't already on our URL...
if [ ! "`echo $url | egrep -c ":[0-9]*$"`" = "1" ]; then
    # add it.
    url="$url:$port"
fi	

# Check for empty user/pass and try reading in from Envvars
if [ "$username" = "" ]; then
    username="$COUCHDB_USER"
fi
if [ "$password" = "" ]; then
   echo password is $password 
   password="$COUCHDB_PASS"
fi

# Check for sed option
sed_edit_in_place='-i.sedtmp'
sed_regexp_option='r'

if [ ! "${username}" = "" ] && [ ! "${password}" = "" ]; then
    curlopt="${curlopt} -u ${username}:${password}"
fi


function checkPrereqs() {
   ## Check for curl
   curl --version >/dev/null 2>&1 || ( echo "... ERROR: This script requires 'curl' to be present."; exit 1 )

   # Check for tr
   echo | tr -d "" >/dev/null 2>&1 || ( echo "... ERROR: This script requires 'tr' to be present."; exit 1 )
}

##### SETUP OUR LARGE VARS FOR SPLIT PROCESSING (due to limitations in split on Darwin/BSD)
AZ2="`echo {a..z}{a..z}`"
AZ3="`echo {a..z}{a..z}{a..z}`"


function renameFile() {
      fileName=$1
      filename=$(basename "$fileName")
      ext="${filename##*.}"
      file="${filename%.*}"
      echo $file-$RANDOM.$ext
}

### If user selected BACKUP, run the following code:
if [ $backup = true ]&&[ $restore = false ]; then
    if [ -f ${file_name} ]; then
        file_name=$(renameFile $file_name)
        echo -e "\t$(timeStamp) INFO: Output file ${file_name_orig} already exists, so renamed $file_name_orig to $file_name"
    fi
    # Fetch data from couchdb
    curl ${curlSilentOpt} ${curlopt} -X GET "$url/$db_name/_all_docs?include_docs=true&attachments=true" -o ${file_name}
    
    # Check for curl errors
    #1. Exit code
    if [ "$?" != "0" ]; then
        echo -e "\t$(timeStamp) ERROR: Curl encountered an issue while dumping the database."
        rm -f ${file_name} &> /dev/null
        exit 1
    fi
    #2. grep file for errors
    ERROR_INFO="$(head -n 1 ${file_name} | grep '^{"error')"
    if [ "${ERROR_INFO}" != "" ]; then
        echo -e "\t$(timeStamp) ERROR: CouchDB reported: $ERROR_INFO"
        exit 1
    fi

    # CouchDB has a tendancy to output Windows carridge returns in it's output -
    # This messes up us trying to sed things at the end of lines!
    if [ "$(file $file_name 2>/dev/null | grep -c CRLF)" = "1" ]||[ "$(file --help >/dev/null 2>&1; echo $?)" != "0" ]; then
        echo -e"\t$(timeStamp) WARN: File may contain Windows carridge returns- converting..."
        filesize=$(du -P -k ${file_name} | awk '{ print $1 }')
        tr -d '\r' < ${file_name} > ${file_name}.tmp
        if [ "$?" = 0 ]; then
            mv ${file_name}.tmp ${file_name}
            if [ "$?" -eq "0" ]; then
                echo -e "\t$(timestamp) INFO: Overwritten ${file_name}.tmp to ${file_name} successfully! "
            else
                echo -e "\t$(timeStamp) ERROR: Failed to overwrite ${file_name}.tmp to ${file_name} :("
                exit 1
            fi
        else
            echo -e "\t$(timeStamp) ERROR: Failed to strip CRLF characters from ${file_name}"
            exit 1
        fi
    fi

    ## Now we parse the output file to make it suitable for re-import.
    $echoVerbose && echo "... INFO: Stage 1 - Document filtering"
    $echoVerbose && echo "... INFO: Amending file to make it suitable for Import."
    # Estimating 80byte saving per line... probably a little conservative depending on keysize.
    KBreduction=$(($((`wc -l ${file_name} | awk '{print$1}'` * 80)) / 1024))
    filesize=$(du -P -k ${file_name} | awk '{print$1}')
    filesize=`expr $filesize - $KBreduction`
    $sed ${sed_edit_in_place} 's/{"id".*,"doc"://g' $file_name && rm -f ${file_name}.sedtmp
    if [ ! $? = 0 ];then
        echo "Stage failed."
        exit 1
    fi

    $echoVerbose && echo "... INFO: Stage 2 - Duplicate curly brace removal"
    # Approx 1Byte per line removed
    KBreduction=$((`wc -l ${file_name} | awk '{print$1}'` / 1024))
    filesize=$(du -P -k ${file_name} | awk '{print$1}')
    filesize=`expr $filesize - $KBreduction`
    $sed ${sed_edit_in_place} 's/}},$/},/g' ${file_name} && rm -f ${file_name}.sedtmp
    if [ ! $? = 0 ];then
        echo "Stage failed."
        exit 1
    fi
    
    $echoVerbose && echo "... INFO: Stage 3 - Header Correction"
    filesize=$(du -P -k ${file_name} | awk '{print$1}')
    $sed ${sed_edit_in_place} '1s/^.*/{"new_edits":false,"docs":[/' ${file_name} && rm -f ${file_name}.sedtmp
    if [ ! $? = 0 ];then
        echo "Stage failed."
        exit 1
    fi
    
    echo -e "$(timeStamp) INFO: Stage 4 - Final document line correction"
    filesize=$(du -P -k ${file_name} | awk '{print$1}')
    $sed ${sed_edit_in_place} 's/}}$/}/g' ${file_name} && rm -f ${file_name}.sedtmp
    if [ ! $? = 0 ];then
        echo "Stage failed."
        exit 1
    fi

    echo -e "\t$(timeStamp) INFO: Export completed successfully. File available as: ${file_name}"

### Else if user selected Restore:
elif [ $restore = true ] && [ $backup = false ]; then
    if [ ! -f "${file_name}" ]; then
        echo -e "\t$(timeStamp) ERROR: Input backup file ${file_name} does not exist!"
        exit 1
    fi

    echo -e "\t$(timeStamp) INFO: Check if the database exists ?"
    existing_dbs=$(curl $curlSilentOpt $curlopt -X GET "${url}/_all_dbs")
    if [ "$?" != "0" ]; then
        echo -e "\t$(timeStamp) ERROR: Curl call failed with exist code non zero. Aborting!"
        exit 1
    fi

    if [[ ! "$existing_dbs" = "["*"]" ]]; then
        echo -e "\t$(timeStamp) ERROR: Curl failed to get the list of databases. Aborting!"
        exit 1
        if [ "$existing_dbs" = "" ]; then
            echo -e "\t$(timeStamp ) INFO: Curl returned the db list => $existing_dbs"
        fi
    # Check if user specified database is in list of  existing databases returned
    elif [[ ! "$existing_dbs" = *"\"${db_name}\""* ]]; then
        if [ "$createDBsOnDemand" = true ]; then
            attemptcount=0
            A=0
            until [ $A = 1 ]; do
                (( attemptcount++ ))
                curl $curlSilentOpt $curlopt -X PUT "${url}/${db_name}" -o tmp.out
                # If curl threw an error:
                if [ "$?" != "0" ]; then
                    if [ "${attemptcount}" = "${attempts}" ]; then
                        echo -e "\t$(timeStamp) ERROR: Curl failed to create the database ${db_name} - Stopping"
                        if [ -f tmp.out ]; then
                            echo -e "\t$(timeStamp) ERROR: Error message was:   "
                            cat tmp.out
                        else
                            echo "ERROR: See above for any errors"
                        fi
                        exit 1
                    else
                        echo -e "\t$(timeStamp) WARN: Curl failed to create the database ${db_name} - Attempt ${attemptcount}/${attempts}. Retrying..."
                        sleep 1
                    fi
                # Checking if CouchDB returned an error in the JSON returned
                elif [ ! "`head -n 1 tmp.out | grep -c 'error'`" = 0 ]; then
                    if [ $attemptcount = $attempts ]; then
                        echo "... ERROR: CouchDB Reported: `head -n 1 tmp.out`"
                        exit 1
                    else
                        echo "... WARN: CouchDB Reported an error during db creation - Attempt ${attemptcount}/${attempts} - Retrying..."
                        sleep 1
                    fi
                # Otherwise, if everything went well, delete our temp files.
                else
                    rm tmp.out
                    A=1
                fi
            done
        else
            echo -e "\t$(timeStamp) ERROR: corresponding datababase ${db_name} not yet created - Stopping"
            echo -e "\t$(timeStamp) INFO: Please pass -c option along with -d <dbName> to create the database at run time"
            exit 1
        fi
    fi

    ## Stop bash mangling wildcard...
    set -o noglob
    # Manage Design Documents as a priority, and remove them from the main import job
    echo "INFO: Checking for Design documents"
    
    # Find all _design docs, put them into another file
    design_file_name=${file_name}-design
    grep '^{"_id":"_design' ${file_name} > ${design_file_name}

    # Count the design file (if it even exists)
    DESIGNS="$(wc -l ${design_file_name} 2>/dev/null | awk '{print$1}')"
    
    # If there's no design docs for import...
    if [ "$DESIGNS" = "" ]||[ "$DESIGNS" = "0" ]; then 
        # Cleanup any null files
        rm -f ${design_file_name} 2>/dev/null
        echo -e "\t$(timeStamp) INFO: No design documents to import."
    else
        echo -e "\t$(timeStamp) INFO: Duplicating original file for alteration"
        # Make a copy of the  original input DB file as to not  mangle the user's input file
        
        filesize=$(du -P -k ${file_name} | awk '{print$1}')
        $sed ${sed_edit_in_place} '/^{"_id":"_design/d' ${file_name} && rm -f ${file_name}.sedtmp
        
        # Remove the final document's trailing comma
        echo -e "\t$(timeStamp) INFO: Fixing end document"
        line=$(expr `wc -l ${file_name} | awk '{print$1}'` - 1)
        filesize=$(du -P -k ${file_name} | awk '{print$1}')
                tr -d '\r' < ${design_file_name}.${designcount} > ${design_file_name}.${designcount}.tmp
                if [ $? = 0 ]; then
                    mv ${design_file_name}.${designcount}.tmp ${design_file_name}.${designcount}
                    if [ $? = 0 ]; then
                        $echoVerbose && echo "... INFO: Completed successfully."
                    else
                        echo "... ERROR: Failed to overwrite ${design_file_name}.${designcount} with ${design_file_name}.${designcount}.tmp"
                        exit 1
                    fi
                else
                    echo ".. ERROR: Failed to convert file."
                    exit 1
                fi
            fi

            # Insert this file into the DB
            A=0
            attemptcount=0
            until [ $A = 1 ]; do
                (( attemptcount++ ))
                curl $curlSilentOpt ${curlopt} -T ${design_file_name}.${designcount} -X PUT "${url}/${db_name}/${URLPATH}" -H 'Content-Type: application/json' -o ${design_file_name}.out.${designcount}
                # If curl threw an error:
                if [ ! $? = 0 ]; then
                     if [ $attemptcount = $attempts ]; then
                         echo "... ERROR: Curl failed trying to restore ${design_file_name}.${designcount} - Stopping"
                         exit 1
                     else
                         echo "... WARN: Import of ${design_file_name}.${designcount} failed - Attempt ${attemptcount}/${attempts}. Retrying..."
                         sleep 1
                     fi
                # If curl was happy, but CouchDB returned an error in the return JSON:
                elif [ ! "`head -n 1 ${design_file_name}.out.${designcount} | grep -c 'error'`" = 0 ]; then
                     if [ $attemptcount = $attempts ]; then
                         echo "... ERROR: CouchDB Reported: `head -n 1 ${design_file_name}.out.${designcount}`"
                         exit 1
                     else
                         echo "... WARN: CouchDB Reported an error during import - Attempt ${attemptcount}/${attempts} - Retrying..."
                         sleep 1
                     fi
                # Otherwise, if everything went well, delete our temp files.
                else
                     A=1
                     rm -f ${design_file_name}.out.${designcount}
                     rm -f ${design_file_name}.${designcount}
                fi
            done
            # Increase design count - mainly used for the INFO at the end.
            (( designcount++ ))
        # NOTE: This is where we insert the design lines exported from the main block
        done < <(cat ${design_file_name})
        $echoVerbose && echo "... INFO: Successfully imported ${designcount} Design Documents"
    fi
    set +o noglob

    # If the size of the file to import is less than our $lines size, don't worry about splitting
    if [ `wc -l $file_name | awk '{print$1}'` -lt $lines ]; then
        $echoVerbose && echo "... INFO: Small dataset. Importing as a single file."
        A=0
        attemptcount=0
        until [ $A = 1 ]; do
            (( attemptcount++ ))
            curl $curlSilentOpt $curlopt -T $file_name -X POST "$url/$db_name/_bulk_docs" -H 'Content-Type: application/json' -o tmp.out
            if [ "`head -n 1 tmp.out | grep -c 'error'`" -eq 0 ]; then
                $echoVerbose && echo "... INFO: Imported ${file_name_orig} Successfully."
                rm -f tmp.out
                rm -f ${file_name_orig}-design
                rm -f ${file_name_orig}-nodesign
                exit 0
            else
                if [ $attemptcount = $attempts ]; then
                    echo "... ERROR: Import of ${file_name_orig} failed."
                    if [ -f tmp.out ]; then
                        echo -n "... ERROR: Error message was:   "
                        cat tmp.out
                    else
                        echo ".. ERROR: See above for any errors"
                    fi
                    rm -f tmp.out
                    exit 1
                else
                    echo "... WARN: Import of ${file_name_orig} failed - Attempt ${attemptcount}/${attempts} - Retrying..."
                    sleep 1
                fi
            fi
        done
    # Otherwise, it's a large import that requires bulk insertion.
    else
        $echoVerbose && echo "... INFO: Block import set to ${lines} lines."
        if [ -f ${file_name}.splitaaa ]; then
            echo "... ERROR: Split files \"${file_name}.split*\" already present. Please remove before continuing."
            exit 1
        fi
        importlines=`cat ${file_name} | grep -c .`

        # Due to the file limit imposed by the pre-calculated AZ3 variable, max split files is 15600 (alpha x 3positions)
        if [[ `expr ${importlines} / ${lines}` -gt 15600 ]]; then
            echo "... ERROR: Pre-processed split variable limit of 15600 files reached."
            echo "           Please increase the '-l' parameter (Currently: $lines) and try again."
            exit 1
        fi

        $echoVerbose && echo "... INFO: Generating files to import"
        filesize=$(du -P -k ${file_name} | awk '{print$1}')
        ### Split the file into many
        split -a 3 -l ${lines} ${file_name} ${file_name}.split
        if [ "$?" != "0" ]; then
            echo "... ERROR: Unable to create split files."
            exit 1
        fi

        HEADER="$(head -n 1 $file_name)"
        FOOTER="$(tail -n 1 $file_name)"

        count=0
        for PADNUM in $AZ3; do
            PADNAME="${file_name}.split${PADNUM}"
            if [ ! -f ${PADNAME} ]; then
                echo "... INFO: Import Cycle Completed."
                break
            fi

            if [ ! "`head -n 1 ${PADNAME}`" = "${HEADER}" ]; then
                $echoVerbose && echo "... INFO: Adding header to ${PADNAME}"
                filesize=$(du -P -k ${PADNAME} | awk '{print$1}')
                $sed ${sed_edit_in_place} "1i${HEADER}" ${PADNAME} && rm -f ${PADNAME}.sedtmp
            else
                $echoVerbose && echo "... INFO: Header already applied to ${PADNAME}"
            fi
            if [ "$(tail -n 1 ${PADNAME})" != "${FOOTER}" ]; then
                $echoVerbose && echo "... INFO: Adding footer to ${PADNAME}"
                filesize=$(du -P -k ${PADNAME} | awk '{print$1}')
                $sed ${sed_edit_in_place} '$s/,$//g' ${PADNAME} && rm -f ${PADNAME}.sedtmp
                echo "${FOOTER}" >> ${PADNAME}
            else
                $echoVerbose && echo "... INFO: Footer already applied to ${PADNAME}"
            fi

            $echoVerbose && echo "... INFO: Inserting ${PADNAME}"
            A=0
            attemptcount=0
            until [ $A = 1 ]; do
                (( attemptcount++ ))
                curl $curlSilentOpt $curlopt -T ${PADNAME} -X POST "$url/$db_name/_bulk_docs" -H 'Content-Type: application/json' -o tmp.out
                if [ ! $? = 0 ]; then
                    if [ $attemptcount = $attempts ]; then
                        echo "... ERROR: Curl failed trying to restore ${PADNAME} - Stopping"
                        exit 1
                    else
                        echo "... WARN: Failed to import ${PADNAME} - Attempt ${attemptcount}/${attempts} - Retrying..."
                        sleep 1
                    fi
                elif [ ! "`head -n 1 tmp.out | grep -c 'error'`" = 0 ]; then
                    if [ $attemptcount = $attempts ]; then
                        echo "... ERROR: CouchDB Reported: `head -n 1 tmp.out`"
                        exit 1
                    else
                        echo "... WARN: CouchDB Reported and error during import - Attempt ${attemptcount}/${attempts} - Retrying..."
                        sleep 1
                    fi
                else
                    A=1
                    rm -f ${PADNAME}
                    rm -f tmp.out
                    (( count++ ))
                fi
            done
            echo -e "\t$(timeStamp) INFO: Imported $(expr ${count}) files"
            A=1
            rm -f ${file_name_orig}-design ${file_name_orig}-nodesign
        done
    fi
fi
