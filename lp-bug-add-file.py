#!/usr/bin/python3
# Created by Roel Van de Paar, Percona LLC

# https://help.launchpad.net/API/launchpadlib  - main API info
# https://help.launchpad.net/API/Examples      - intial examples
# https://help.launchpad.net/API/Uses          - links to real life examples
# http://launchpad.net/+apidoc/                - detailed reference
# https://pypi.python.org/pypi/launchpadlib    - version overview

import sys, getopt, os
from launchpadlib.launchpad import Launchpad

def usage():
  print("** This script needs three paramaters; the Launchpad bug number, the file to upload and the file's description.")
  print("   Usage: ./lp-bug-logger.py -b <bugno> -f <file> -d '<description>'")
  print("** This script is usually not executed directly, but is instead used by lp-bug-logger.sh")
  print("   However, if you use it directly, a 'None' output means there were no errors/that the upload was successful.")
  print("** Some important information on interaction with Launchpad via the Python Launchpad API used by this script:")
  print("   The first time you run this script, you will see something like this (after quite some time):")
  print("   ---------------------------------------------------------------------------------------------------------")
  print("   The authorization page:")
  print("    (https://launchpad.net/+authorize-token?oauth_token=xxxxxxxxxxxxxx&allow_permission=DESKTOP_INTEGRATION)")
  print("   should be opening in your browser. Use your browser to authorize this program to access LP on your behalf")
  print("   Waiting to hear from Launchpad about your decision...")
  print("   ---------------------------------------------------------------------------------------------------------")
  print("   When you see this (and assuming you're working in a text-only ssh connection; otherwise a browser may have")
  print("   already automatically opened for you), copy and paste the URL shown into any browser and authorize the app")
  print("   (for example, untill revoked) after logging into LP. This only has to be done once (if you chose an indefinite")
  print("   /untill revoked authorization), and it can be done from any machine (provided you login to LP). If you run")
  print("   into any issues, also review https://bugs.launchpad.net/launchpadlib/+bug/814595 if applicable. And, authorized")
  print("   applications can be viewed (and revoked) at: https://launchpad.net/~<your_lp_user_id>/+oauth-tokens")

def options():
  try:
    opts, args = getopt.getopt(sys.argv[1:],"b:f:d:", ["bug=", "file=", "desc="])
  except getopt.GetoptError as err:
    print (err)
    usage()
    sys.exit(2)
  bugno = 0
  file = 0
  desc = 0
  for o,a in opts:
    if o in ("-b","--bug"):
      bugno = a
    elif o in ("-f","--file"):
      file = a
    elif o in ("-d","--desc"):
      desc = a
    else:
      assert False, "A given option was not recognized by this script"
  if bugno == 0 or file == 0 or desc == 0:
    usage()
    sys.exit(2)
  return bugno, file, desc

def add_attach(bug,file,desc):
  # See https://launchpad.net/+apidoc/1.0.html#bug and scroll down to "addAttachment" under "Custom POST methods"
  bug.addAttachment(comment="",data=open(file, "rb").read(),description=desc,filename=file)
  res=bug.lp_save()
  print(res)

# Init
bugno, file, desc=options()

# Submit files to bug
launchpad = Launchpad.login_with('LP Bug Logger v1.00', 'production')           # R/W
bug = launchpad.bugs[bugno]
print("** Bug Number  : ",bugno)
print("** Bug title   : ",bug.title)
print("** Uploading   : ",file)
print("** Description : ",desc)

add_attach(bug,file,desc)







# ==================================================================================================
# What follows below are currently ununused (but handy for future reference) functions
# ==================================================================================================
def msg(bug):
  #Usage: msg(b)   # Get all messages
  print(b.message_count)
  for m in bug.messages:
    # https://launchpad.net/+apidoc/1.0.html#message
    #print(m)
    print(m.content)

def object_info():
  print(dir(b))   # See Properties (but one can also just check the reference linked to above)
  print(help(b))  # See Methods

def add_msg(bug,mesg,subj):
  # See https://launchpad.net/+apidoc/1.0.html#bug and scroll down to "newMessage" under "Custom POST methods"
  #Usage: add_msg(b,"test comment","test subject")
  bug.newMessage(content=mesg, subject=subj)
  bug.lp_save()

def atc(bug):
  #Usage: atc(b)   # Get all attachments (title/type, unmark below if contents are required)
  for a in bug.attachments:
    # https://launchpad.net/+apidoc/1.0.html#bug_attachment
    # Fetch actual data contents example:
    #  buffer = attachment.data.open()
    #  for line in buffer:
    #      print(line)
    #  buffer.close()
    print("title:", a.title)
    print("ispatch:", a.type)

