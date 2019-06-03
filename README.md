# UniTotem
#### The definitve Raspberry Pi image for kiosk mode

Imagine you want to display the content of a website on a public screen, using a normal computer would certainly be oversized and expensive, so why not to turn to a Raspberry Pi?<br/>
The idea is to build a simple system that does only what you want, minding both the price and the functionality, so here comes out UniTotem: a simple and lightweight Raspberry Pi image that boots up and shows the web page in about 12 seconds.

## Installation guide
#### Necessary components:
  - A Raspberry Pi (I used a Raspberry Pi 3 model B, but every model that supports the latest version of Raspbian should work)
  - A Micro SD card (The whole image is about 2.11GB, so a 4GB micro SD card would be fine)
    - *Important*: The class (= the quality) of the micro SD card really affects boot times; the 12 second boot time is achieved on a [Sandisk Ultra Class 10 16GB micro SD card](https://www.sandisk.com/home/memory-cards/microsd-cards/ultra-microsd-400gb)
  - A 5V micro USB Power supply (I used a 5V@3A power supply and everything worked just fine, probably you won't need such a power supply, so you can try with a less powerful one, until a yellow lightning appears on the top-right corner of the screen, meaning that the system is not receiving enough power.
  - An HDMI display (You can obviously use quite any type of display, but keep in mind that a display that does not support HDMI would mean that you have to use an adapter, since Raspberry Pi uses HDMI for video output)
  - A video cable (Depends on the choice above, however, one side of the cable must be HDMI, otherwise you can't connect it to the Raspberry Pi)
  - An Ethernet cable (This image has no Wireless networking support, the reason will be explained later)
  - A case (optional, _but suggested_) (If you mind protection, you shuold protect the Raspberry Pi, at least, from touching metal parts: you know, electricity and metal aren't such good friends:stuck_out_tongue_winking_eye:)

### Let's install it
##### 1) Download Etcher
Download Etcher from [this page](https://www.balena.io/etcher/), clicking on the big button with caption `Download for...`
##### 2) Download the image
Click the green `Clone or download` button over the list with the files, then select `Download ZIP`.
##### 3) Wait
The download may take some time depending on your Internet Speed, so go and enjoy some good music.
##### 4) Prepare the SD card
If your computer has a port for SD cards, get a micro SD - SD card adapter, insert your micro SD in it and then insert it into your computer.<br/>
Otherwise, if your computer doesn't have one, take an USB SD card reader, if yours directly supports micro SDs, insert it and then plug the reader in a USB port, if not, grab an adapter like above.<br/>
After you inserted it in your computer and it recognized all the stuff, open a file manager and navigate to your Download folder and look for a file called `balenaEtcher-Setup-X.X` and open it, then look for a file called `unitotem-master.zip`, unzip it and wait for it to complete.<br/>
After you unzipped the zip file, come back to Etcher and click on `Select image` and, navigate to the `unitotem-master` folder and select the file `unitotem-X.img`, then make sure it recognized your SD card, if not, click on `Select drive` and select your SD card, at the end click on `Flash!` and wait again for it to complete.<br/>
##### 5) Configure UniTotem
After the whole process if ended, your computer should have mounted a drive called `boot`, open on it and then open the unitotem folder.<br/>
Look for a file called `unitotem.conf`, open it with your favourite text editor and edit the line `URL="https://github.com/a13ssandr0/unitotem"` placing the url of your website between the `" "`, then save and close.<br/>
Now look for another file called `splash.png`, replace it with your custom image (it will be displayed when the system boots up before the web browser starts), but remember to save it as a png image, with the same name as the original file.<br/>
Now that all is finished, safely unmount the SD card and insert it in your Raspberry Pi.
##### 6) Connect all
Connect all the cables to your Raspberry Pi and power it on.<br/>
In a bunch of seconds you should see the splash image and then the web browser should appear.<br/>
If everything worked, the website should appear on the screen.

### Final thoughts
  ##### Network
  - As I said before, the system has neither wifi nor bluetooth support (I uninstalled and disabled the services and drivers) because the wireless service would have taken about 4-5 seconds to start, slowing down the boot process, while the bluetooth could have led also to security problems (you can search on the Internet for the problems related to bluetooth)
  - The default network settings are:
  ```
  dhcp: no
  ip address: 192.168.1.10
  netmask: 255.255.255.0
  gateway: 192.168.1.1
  dns: 192.168.1.1, 1.1.1.1
  ```
  ##### SSH and login
  The username is `pi`<br/>
  The default password is `unitotem` both for `pi` and for `root`, you should change this in order to prevent someone from changing your settings.
  ##### Power off
  As you may have noticed, the Raspberry Pi has no power button; there would be no problem for power up as soon as the Raspebrry Pi automatically powers on when the usb cable is connected, but for power down you would need to open the ssh terminal and send the command `sudo poweroff` every time, and unplugging the power cord when the Raspberry Pi is running is **strongly advised against**.<br/>
  However, there are two solutions:<br/>
  1) Connecting a pushbutton between the pins 5 and 6 of the header<br/>
  UniTotem is already configured to accept a pushbutton connected directly to pins 5-6 like in the image below.<br/>
    ![Raspberry shutdown button connection](https://github.com/a13ssandr0/unitotem/blob/master/Raspberry%20shutdown%20button.png)
  2) Programming a shutdown scheduler with _cron_, adding this line to `/etc/crontab`:<br/>
    Login with ssh on the Raspberry Pi<br/>
    Type
    ```bash
    sudo nano /etc/crontab
    ```
    and enter the password when/if asked.
    Go to the end of the file and add this line
    ```
    30 23 * * * root poweroff
    ```
    changing the nubers 30 and 23 with respectively the minute and hour of the desidered shutdown.
    
