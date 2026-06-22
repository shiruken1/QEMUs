class Samba < Formula
  # Pinned to 4.16.4 ON PURPOSE. Do not bump to 4.17+.
  #
  # Samba >= 4.17 has a macOS regression that breaks QEMU user-mode SMB shares:
  # when smbd switches user (guest / `force user`) it hits an `unbecome_root`
  # `errno` bug and returns NT_STATUS_ACCESS_DENIED on writes, even though the
  # write physically succeeds. This makes Visual Studio / MSBuild builds onto the
  # share fail with "access to the path is denied". 4.16.x predates the bug.
  # See: https://gitlab.com/qemu-project/qemu/-/work_items/1299
  #
  # This is the Homebrew core 4.16.4 formula with two macOS-build fixes vs. the
  # original: python@3.9 (4.16's waf needs distutils, removed in 3.12) and
  # explicit zlib + pkgconf deps (not auto-found on current macOS).
  desc "SMB/CIFS file, print, and login server for UNIX"
  homepage "https://www.samba.org/"
  url "https://download.samba.org/pub/samba/stable/samba-4.16.4.tar.gz"
  sha256 "9532f848fb125a17e4e5d98e1ae8b42f210ed4433835e815b97c5dde6dc4702f"
  license "GPL-3.0-or-later"

  # configure requires a python3 binary even with --disable-python, and 4.16's
  # waf build uses distutils, which was removed in Python 3.12 -> use 3.9.
  depends_on "pkgconf" => :build
  depends_on "python@3.9" => :build
  depends_on "gnutls"
  depends_on "krb5"
  depends_on "libtasn1"
  depends_on "readline"
  depends_on "zlib"

  uses_from_macos "bison" => :build
  uses_from_macos "flex" => :build
  uses_from_macos "perl" => :build
  uses_from_macos "libxcrypt"

  on_macos do
    depends_on "openssl@1.1"
  end

  resource "Parse::Yapp" do
    url "https://cpan.metacpan.org/authors/id/W/WB/WBRASWELL/Parse-Yapp-1.21.tar.gz"
    sha256 "3810e998308fba2e0f4f26043035032b027ce51ce5c8a52a8b8e340ca65f13e5"
  end

  def install
    # avoid `perl module "Parse::Yapp::Driver" not found` error on macOS 10.xx (not required on 11)
    if MacOS.version < :big_sur
      ENV.prepend_create_path "PERL5LIB", buildpath/"lib/perl5"
      ENV.prepend_path "PATH", buildpath/"bin"
      resource("Parse::Yapp").stage do
        system "perl", "Makefile.PL", "INSTALL_BASE=#{buildpath}"
        system "make"
        system "make", "install"
      end
    end
    ENV.append "LDFLAGS", "-Wl,-rpath,#{lib}/private" if OS.linux?
    system "./configure",
           "--disable-cephfs",
           "--disable-cups",
           "--disable-iprint",
           "--disable-glusterfs",
           "--disable-python",
           "--without-acl-support",
           "--without-ad-dc",
           "--without-ads",
           "--without-ldap",
           "--without-libarchive",
           "--without-json",
           "--without-pam",
           "--without-regedit",
           "--without-syslog",
           "--without-utmp",
           "--without-winbind",
           "--with-shared-modules=!vfs_snapper",
           "--with-system-mitkrb5",
           "--prefix=#{prefix}",
           "--sysconfdir=#{etc}",
           "--localstatedir=#{var}"
    system "make"
    system "make", "install"
    if OS.mac?
      # macOS has its own SMB daemon as /usr/sbin/smbd, so rename our smbd to
      # samba-dot-org-smbd to avoid conflict. samba-dot-org-smbd is used by qemu.
      mv sbin/"smbd", sbin/"samba-dot-org-smbd"
      mv bin/"profiles", bin/"samba-dot-org-profiles"
    end
  end

  def caveats
    on_macos do
      <<~EOS
        To avoid conflicting with macOS system binaries, some files were installed with non-standard name:
        - smbd:     #{HOMEBREW_PREFIX}/sbin/samba-dot-org-smbd
        - profiles: #{HOMEBREW_PREFIX}/bin/samba-dot-org-profiles
      EOS
    end
  end

  test do
    smbd = OS.mac? ? "#{sbin}/samba-dot-org-smbd" : "#{sbin}/smbd"
    system smbd, "--version"
  end
end
