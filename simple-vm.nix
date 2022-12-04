# source: https://gist.github.com/zhaofengli/275d1a0de14eceba90fd4e399af34b5c
# build: nix-build simple-vm.nix
# run: sudo ./result
with builtins;
let
  pkgs = import ./. {};
  cross = pkgs.pkgsCross.riscv64;
  kernel = cross.linuxPackages_5_15.kernel;
  busybox = cross.busybox.override { enableStatic = true; };

  memory = "1G";
  smp = 4;

  requiredModules = [ "9p" "virtio" "9pnet_virtio" "virtio_net" "virtio_rng" "virtio_mmio" ];

  init = pkgs.writeScript "init" ''
    #!${busybox}/bin/sh
    export PATH=${cross.kmod}/bin:${busybox}/bin

    mkdir -p /sys /proc /dev /lib /host

    mount -t proc none /proc
    mount -t sysfs none /sys
    mount -t devtmpfs none /dev

    ln -s ${modules}/lib/modules /lib/modules
    ${concatStringsSep "\n" (map (x: "modprobe ${x}") requiredModules)}

    # Too lazy to even switch root :P
    if mount -t 9p -o trans=virtio,msize=12582912 nix /nix; then
      echo "Mounted host /nix/store"

      if mount -t 9p -o trans=virtio,msize=12582912 pwd /host; then
        echo "Mounted host PWD at /host"
      fi
    else
      echo "We don't have access to host /nix/store. Run the script as root to mount the host Nix store."
    fi

    echo "Hello from RISC-V! Press Ctrl-A then x to terminate QEMU."
    exec sh
  '';

  modules = cross.callPackage (pkgs.path + "/pkgs/build-support/kernel/modules-closure.nix") {
    inherit kernel;
    firmware = null;
    rootModules = requiredModules;
  };

  initrd = cross.callPackage (pkgs.path + "/pkgs/build-support/kernel/make-initrd.nix") {
    contents = [
      {
        object = init;
        symlink = "/init";
      }
    ];
  };
in pkgs.writeShellScript "simple-vm.sh" ''
  MOUNT_ARGS=""

  if test "$(id -u)" -eq "0"; then
    MOUNT_ARGS+=" -device virtio-9p-device,id=nix,fsdev=nixfs,mount_tag=nix"
    MOUNT_ARGS+=" -fsdev local,id=nixfs,path=/nix,security_model=none,writeout=immediate"
    MOUNT_ARGS+=" -device virtio-9p-device,id=pwd,fsdev=pwdfs,mount_tag=pwd"
    MOUNT_ARGS+=" -fsdev local,id=pwdfs,path=`pwd`,security_model=none,writeout=immediate"
  fi

  exec ${pkgs.qemu}/bin/qemu-system-riscv64 -nographic \
    -machine virt -cpu rv64 -m ${memory} -smp ${toString smp} \
    -kernel ${kernel}/Image -initrd ${initrd}/initrd -append "console=ttyS0" \
    -object rng-random,filename=/dev/urandom,id=rng \
    -device virtio-rng-device,rng=rng \
    -device virtio-net-device,netdev=net -netdev user,id=net \
    $MOUNT_ARGS
''
