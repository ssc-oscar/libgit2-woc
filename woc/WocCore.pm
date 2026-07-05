package WocCore;
# ---------------------------------------------------------------------------
# WocCore -- lightweight, DEPENDENCY-FREE WoC core utilities.
# Deliberately pure-perl: NO Compress::LZF, NO TokyoCabinet, no XS. This makes it
# safe to `use` from the lightweight discovery/clone tools (gather_new, libgit2-woc)
# that must stay small-VM / clone0 deployable, as well as from the heavy woc.pm
# (which `use`s this and re-exports, so `use woc; url2woc(...)` keeps working).
#
# SINGLE SOURCE OF TRUTH for the repository-URL <-> WoC-project-name conversion.
# See coord/url2woc-unification-audit.md for every call site being unified onto this.
# ---------------------------------------------------------------------------
use strict;
use warnings;
use Exporter 'import';
our @EXPORT    = qw(url2woc woc2url
  toHex fromHex segB segH simpEmail getFL parseAuthorId is_crud
  splitSignature signature_error contains_angle_brackets extract_trimmed git_signature_parse);
our @EXPORT_OK = qw(url2woc woc2url %WOC_FORGE);

# Forges whose CLONE host differs from the host embedded in the WoC name (name-host -> clone-host).
# Most forges are identity (name host == clone host); only these few remap. Used by woc2url.
our %WOC_HOST_REWRITE = (
  "sourceforge.net"      => "git.code.sf.net/p",
  "git.kernel.org"       => "git.kernel.org/pub/scm",
  "drupal.com"           => "git.drupal.org",
  "kde.org"              => "anongit.kde.org",
);

# url2woc: repository URL -> WoC project name (the canonical rule, user 2026-06-15):
#   1. drop scheme (https|http|git|ssh|git+...); scp form git@host:owner/repo -> host/owner/repo
#   2. strip trailing '/' and trailing '.git'  (STRIP_SLASH / STRIP_GIT env, default on)
#   3. replace the FIRST TWO '/' with '_'  (deeper paths keep their remaining slashes)
#   4. lowercase
#   5. drop a leading 'github.com_'  (github -> bare owner_repo; other forges keep their host)
# e.g. https://github.com/Torvalds/Linux -> torvalds_linux ;
#      https://gitlab.com/grp/sub/repo    -> gitlab.com_grp_sub/repo
sub url2woc {
  my $p = $_[0];
  return $p unless defined $p && length $p;
  my $strip_git   = defined $ENV{STRIP_GIT}   ? $ENV{STRIP_GIT}   : 1;
  my $strip_slash = defined $ENV{STRIP_SLASH} ? $ENV{STRIP_SLASH} : 1;
  $p =~ s|^[a-z][a-z0-9+.\-]*://||i;          # drop scheme://
  $p =~ s|^git\@([^:]+):|$1/|;                # scp-form git@host:owner/repo -> host/owner/repo
  $p =~ s|/+$|| if $strip_slash;              # trailing slash
  $p =~ s|\.git$|| if $strip_git;             # trailing .git
  $p =~ s|/|_|;                               # first slash
  $p =~ s|/|_|;                               # second slash
  $p = lc $p;
  $p =~ s|^github\.com_||;                     # github -> bare owner_repo (classic WoC form)
  return $p;
}

# woc2url: WoC project name -> repository URL (structural inverse of url2woc).
#   host = the first '_'-token IF it contains a '.' (a forge host); otherwise github.com (bare
#   owner_repo). The first '_' after the host is the owner/repo boundary (deeper slashes were
#   preserved by url2woc). A few forges clone from a different host than the name embeds
#   (%WOC_HOST_REWRITE). Supersedes the old woc::toUrl, which keyed on short codes and so
#   mis-mapped full-host names (bitbucket.org_*, gitlab.com_*) to github.
sub woc2url {
  my $n = $_[0];
  return $n unless defined $n && length $n;
  my ($host, $rest);
  if ($n =~ /^([^_]*\.[^_]+)_(.*)$/) { ($host, $rest) = ($1, $2); }   # forge host = dotted first token
  else                               { ($host, $rest) = ("github.com", $n); }  # bare -> github
  $host = $WOC_HOST_REWRITE{$host} if exists $WOC_HOST_REWRITE{$host};
  $rest =~ s|_|/|;                                                    # first '_' -> owner/repo slash
  return "https://$host/$rest";
}


# ---- pure-perl utilities relocated from woc.pm (single source; woc.pm re-exports) ----
sub toHex {
        return unpack "H*", $_[0];
}
sub fromHex {
        return pack "H*", $_[0];
}
sub segB {
  my ($s, $n) = @_;
  return (unpack "C", substr ($s, 0, 1))%$n;
}


sub segH {
  my ($sh, $n) = @_;
  return (unpack "C", substr (fromHex($sh), 0, 1))%$n;
}

sub simpEmail {
  my $eO = $_[0];
  return "" if $eO eq "";
  my $e = $eO;
  $e =~ s|git config.*||;
#$e =~ s|�~@~\||g;#$e =~ s|�~@~\||g;
  $e =~ s|�~@~]||g;
  $e =~ s|�~@~X||g;
  $e =~ s|¨||g;
  $e =~ s|«||;
  $e =~ s|»||g;
  $e =~ s|�~@~Y||g;
  $e =~ s|�~@~^||g;

  $eO = $e;

  my @z = split(/\@/, $e);
  my $d = $z[1];
  if (defined $d && $d ne "" && $d !~ m/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/){
    $d =~ s|^[^\.]*\.noreply\.||;
    $d =~ s|/.*||;
    my @y = split(/\./,$d,-1);
    shift @y if ($y[0] =~ m/[0-9]/ && $#y > 1);
    pop @y if $d =~ m/\.(local|localdomain)$/;
    $d = join ".", @y;
    $eO = "$z[0]\@$d";
  }
  return $eO;
}


sub getFL {
  my $a = $_[0];
  my $a0 = $a;
  $a =~ s/\s+\<.*//;
  if ($a =~ /([a-zA-Z0-9_\.]+@[a-zA-Z0-9]+\.[a-z]+)/){#has email in the name space
    my $e0 = $1;
    my $e = $e0;
    $e0 =~ s/@.*//;
    $e0 =~ s|^["\s\{\}\(\)\r#!%\$'/\&\*\+]*||;
    $e0 =~  s|["\s\{\}\(\)\r#!%\$'/\&\*\+]*$||;
    $e0 =~ s|([a-z])([A-Z])([A-Z])|$1.$2.$3|g; #Camelback
    $e0 =~ s|([a-z])([A-Z])|$1.$2|g; #Camelback
    my @as1 = split (/[\._\-]/, $e0);
    if ($#as1 > 1){ #use names derived from email
      return "$as1[0] $as1[$#as1]";
    }else{
      #remove email
      $a =~ s/$e0//;
    }
  }
  $a =~ s|^["\s\{\}\(\)\r#!%\$'/\&\*\+\.\-@]*||;
  $a =~  s|["\s\{\}\(\)\r#!%\$'/\&\*\+\.\-@]*$||;
  $a =~ s|[\.,\-\s]+| |g;
  $a =~ s|([a-z])([A-Z])([A-Z])|$1 $2 $3|g; #Camelback
  $a =~ s|([a-z])([A-Z])|$1 $2|g; #Camelback
  $a =~ s|\bMc ([A-Z])|Mc$1|;
  $a =~ tr/[A-Z]/[a-z]/;
  $a =~ s/^\s*$//;
  $a =~ s/^[0-9]*$//;
  if ($a ne ""){
    #print STDERR "here0;$a;\n";
    my @as=split(/ /,$a);
    pop @as if ($#as > 1 && $as[$#as] =~ m/^([iv]|[iv][iv]|ii[iv]|vii|jr|sr|phd|md|dds)$/);
    #print STDERR "here0:$a:$a0\n";
    return "$as[0] $as[$#as]" if $#as > 0;
    # handle singleword concatenated firstlast names in the future
    return "$as[0]";
  }else{#check email
    $a = $a0;
    $a =~ s/.*\<//;
    $a =~ s/\>.*//;
    $a =~ s|^["\s\{\}\(\)\r#!%\$'/\&\*\+,\.\-]*||;
    $a =~ s|["\s\{\}\(\)\r#!%\$'/\&\*\+,\.\-@]*$||;
    $a =~ s/@.*//;
    $a =~ s|([a-z])([A-Z])|$1 $2|g;
    $a =~ s/[\._-]/ /g;
    my @as = split (/ /, $a);
    my $res = "";
    for my $i (0..$#as){
      $res .= ";$as[$i]" if $as[$i] ne "" && $as[$i] !~ /^[0-9]*$/;
    }
    $res =~ s/^;//;
    if ($res ne ""){
      $res =~ tr/[A-Z]/[a-z]/;
      @as = split (/;/, $res);
      pop @as if ($#as > 1 && $as[$#as] =~ m/^([iv]|[iv][iv]|ii[iv]|vii|jr|sr|phd|md|dds)$/);
      #print STDERR "here1\n";
      return "$as[0] $as[$#as]" if $#as > 0;
      return "$as[0]";
      # handle singleword concatenated firstlast usernames in the future
      # e.g., fabianlevin88@hotmail.com, amockus1@gmail.com 
    }
  }
  return "";
}
sub parseAuthorId{
  my $a = $_[0];
  my $a0 = $a;
    
 
  my ($f, $l) = split (/ /, getFL($a), -1);
  $f = "" if !defined $f;
  $l = "" if !defined $l;
  my $e = $a;
  $e =~ s/.*\<//;
  $e =~ s|\{ID\}\+\{||;
  $e =~ s|[}{]||g;
  $e =~ s/\>.*//;
  $e =~ s|^[\s\{\}\(\)\r#!%\$"'/\&\*\+,\.\-]*||;
  $e =~ s|[\s\{\}\(\)\r#!%\$"'/\&\*\+,\.\-]*$||;
  $e =~ tr/[A-Z]/[a-z]/;
  my $ghid = "";
  if ($e =~ m/([^\+ ]+)\@(users.noreply.github.com|users.github.com|noreply.users.github.com)/ && defined $1){ #get github hadnle
    $e = $1;
    $e =~ s|^["\s\{\}\(\)\r#!%\$'/\&\*\+,\.\-]*||;
    $e =~ s|["\s\{\}\(\)\r#!%\$'/\&\*\+,\.\-]*$||;
    $e .= '@users.noreply.github.com';
    $ghid = $e;
    $ghid =~ s/\@.*//;
  }
  my ($u, $d) = split(/\@/, $e);
  $u = "" if !defined $u;
  $d = "" if !defined $d;
  return ($f, $l, $u, $d, $e, $ghid, $a);
} 

sub is_crud {
   my $c = $_[0];
   return  ord($c) <= 32  ||
                $c eq '.' ||
                $c eq ',' ||
                $c eq ':' ||
                $c eq ';' ||
                $c eq '<' ||
                $c eq '>' ||
                $c eq '"' ||
                $c eq '\\' ||
                $c eq '\'';
}

sub splitSignature {
  my $s = $_[0];
  return git_signature_parse ($s, "");
}

sub signature_error {
        my ($msg, $data) = @_;
        print STDERR  "failed to parse signature - $msg\n";
        return ($data, "");
}

sub contains_angle_brackets{ 
   my $input = $_[0];
        return index ($input, '<') >= 0 || index ($input, '>') >= 0;
}

sub extract_trimmed {
   my ($ptr, $len) = @_;
   $ptr = substr($ptr, 0, $len);
   my $off = 0;
   while (is_crud (substr($ptr, $off, 1)) && $len > 0) {
                $off++; $len--;
   }
   $ptr = substr ($ptr, $off, $len);
   $off = 0;
   while ($len && is_crud (substr($ptr, $len-1, 1))) {
        $len--;
   }
   return substr ($ptr, 0, $len);
}

sub git_signature_parse {
   my ($buffer, $cmt) = @_;
   my $email_start = index ($buffer, '<');
   my $email_end = index ($buffer, '>');
   if ($email_start < 0 || !$email_end || $email_end <= $email_start){
      if ($email_end < $email_start){
        print STDERR  "in $cmt malformed e-mail ($email_start, $email_end): $buffer\n";
        $buffer =~ s/\>// if $email_end >= 0;
        $buffer =~ s/$/\>/ if $email_end < 0;
        return git_signature_parse ($buffer, $cmt);
      }else{
        return signature_error("in $cmt malformed e-mail ($email_start, $email_end): $buffer", $buffer);
      }
   }
   $email_start += 1;
   my $name = extract_trimmed ($buffer, $email_start - 1);
   my $email = substr($buffer, $email_start, $email_end - $email_start);
   $email = extract_trimmed($email, $email_end - $email_start);

   return ($name, $email);
}


1;
