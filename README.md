# UniTotem
#### The definitve Raspberry Pi image for kiosk mode

Imagine you want to display the content of a website on a public screen, using a normal computer would certainly be oversized and expensive, so why not to turn to a Raspberry Pi?
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
Download Etcher from [this page](https://www.balena.io/etcher/), by clicking on the big button with caption `Download for...`
##### 2) Download the image
Click the green `Clone or download` button over the list with the files, then select `Download ZIP`.
##### 3) Wait
The download may take some time depending on your Internet Speed, so go and enjoy some good music.
##### 4) Prepare the SD card
If your computer has a port for SD cards, get a micro SD - SD card adapter, insert your micro SD in it and then insert it into your computer.
Otherwise, if your computer doesn't have one, take an USB SD card reader, if yours directly supports micro SDs, insert it and then plug the reader in a USB port, if not, grab an adapter like above.
After you inserted it in your computer and it recognized all the stuff, open a file manager and navigate to your Download folder and look for a file called `balenaEtcher-Setup-X.X` and open it.
When the program starts click on `Select image` and select the file `unitotem-X.img`, then make sure it recognized your SD card, if not, click on `Select drive` and select your SD card, at the end click on `Flash!` and wait again for it to complete.
##### 5) Configure UniTotem
After the whole process if ended, your computer should have mounted a drive called `boot`, open on it and then open the unitotem folder
