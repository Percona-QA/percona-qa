#!/bin/bash

# This script installs protractor and all packages required for PMM e2e testing on Ubuntu

##############################################################
# Check if package is not installed and then install it 
# Arguments: package's name
##############################################################
check_package_installed() {
  if [ $(dpkg-query -W -f='${Status}' $1 2>/dev/null | grep -c "ok installed") -eq 0 ];
    then
     apt-get install $1 > /dev/null 2>&1;
     echo Package $1 has been installed
  fi
}

##############################################################
# Check if npm module is installed globally
# Arguments: module's name
##############################################################
check_npm_package_installed() {
  npm list --depth 1 -g $1 > /dev/null 2>&1
}

##############################################################
# Check if npm module is installed locally
# Arguments: module's name
##############################################################
check_npm_package_installed_l() {
  npm list --depth 1  $1 > /dev/null 2>&1
}

echo Checking installed packages
check_package_installed default-jre
check_package_installed nodejs
check_package_installed npm

if check_npm_package_installed protractor; then
  echo Protractor is already installed
  else
  npm install -g protractor
fi


for package in protractor-jasmine2-screenshot-reporter jasmine-reporters; do
    if check_npm_package_installed_l $package; then
        echo $package is already installed
      else
        npm install $package
        echo npm $package has been installed globally
    fi
done

