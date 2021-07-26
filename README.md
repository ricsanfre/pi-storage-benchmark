# Benchmarking Storage options for Raspberry Pi

The scope of this project is benchmarking the different storage options at my disposal for running Ubuntu 20.04 on RaspberryPI
Different options that will be tested are:

1) Internal SDCard
2) External USB 3.0 (no SSD)
3) SCSI using a Target SCSI running on Raspberry PI using as USB 3.0 SSD disk

For the testing a tweaked version of the [script](https://raw.githubusercontent.com/TheRemote/PiBenchmarks/master/Storage.sh) provided by James A. Chambers (https://jamesachambers.com/) will be used

> NOTE: see https://pibenchmarks.com/ for details about Raspberry PI storage benchmarking results

## Benchmarking Procedure

### Sequential I/O performance

Test sequential I/O with `dd` and `hdparam` tools. `hdparm` can be installed through `sudo apt install -y hdparm`


- Read speed (Use `hdparm` command)
    
    ```
    sudo hdparm -t /dev/sda1
    
    Timing buffered disk reads:  72 MB in  3.05 seconds =  23.59 MB/sec

    sudo hdparm -T /dev/sda1
    Timing cached reads:   464 MB in  2.01 seconds = 231.31 MB/sec
    ```

    It can be combined in just one command:

    ```
    sudo hdparm -tT --direct /dev/sda1

    Timing O_DIRECT cached reads:   724 MB in  2.00 seconds = 361.84 MB/sec
    Timing O_DIRECT disk reads: 406 MB in  3.01 seconds = 134.99 MB/sec

    ```

- Write Speed (use `dd` command)

    ```
    sudo dd if=/dev/zero of=test bs=4k count=80k conv=fsync

    81920+0 records in
    81920+0 records out
    335544320 bytes (336 MB, 320 MiB) copied, 1,86384 s, 180 MB/s

    ```
### Random I/O Performance

Tools used `fio` and `iozone`

Install required packages with:

    sudo apt install iozone3 fio

- Check random I/O with `fio`

    Random Write

    ```
    sudo fio --minimal --randrepeat=1 --ioengine=libaio --direct=1 --gtod_reduce=1 --name=test --filename=test --bs=4k --iodepth=64 --size=80M --readwrite=randwrite
    ```

    Random Read


    ```
    sudo fio --minimal --randrepeat=1 --ioengine=libaio --direct=1 --gtod_reduce=1 --name=test --filename=test --bs=4k --iodepth=64 --size=80M --readwrite=randread
    ```

- Check random I/O with `iozone`

    ```
    sudo iozone -a -e -I -i 0 -i 1 -i 2 -s 80M -r 4k

    ```
