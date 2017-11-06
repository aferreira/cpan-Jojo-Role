
package Jojo::Role;

use 5.018;
use strict;
use warnings;

BEGIN {
  require Role::Tiny;
  Role::Tiny->VERSION('2.000001');
  our @ISA = qw(Role::Tiny);
}

use Sub::Inject 0.3.0 ();

# Aliasing of Role::Tiny symbols
BEGIN {
  *INFO = \%Role::Tiny::INFO;
  *APPLIED_TO = \%Role::Tiny::APPLIED_TO;
  *COMPOSED = \%Role::Tiny::COMPOSED;
  *COMPOSITE_INFO = \%Role::Tiny::COMPOSITE_INFO;
  *ON_ROLE_CREATE = \@Role::Tiny::ON_ROLE_CREATE;

  *_getstash = \&Role::Tiny::_getstash;
}

our %INFO;
our %APPLIED_TO;
our %COMPOSED;
our %COMPOSITE_INFO;
our @ON_ROLE_CREATE;

sub import {
  my $target = caller;
  my $me = shift;
  $_->import for qw(strict warnings);

  my $flag = shift;
  if (!$flag) {
    @_ = $me->_become_role($target);
  }

  elsif ($flag eq '-with') {
     @_ = $me->_generate_subs($target, qw(with));
  }
  goto &Sub::Inject::sub_inject;
}

sub _become_role {
  my ($me, $target) = @_;
  return if $me->is_role($target); # already exported into this package
  $INFO{$target}{is_role} = 1;
  # get symbol table reference
  my $stash = _getstash($target);
  # grab all *non-constant* (stash slot is not a scalarref) subs present
  # in the symbol table and store their refaddrs (no need to forcibly
  # inflate constant subs into real subs) with a map to the coderefs in
  # case of copying or re-use
  my @not_methods = map +(ref $_ eq 'CODE' ? $_ : ref $_ ? () : *$_{CODE}||()), values %$stash;
  @{$INFO{$target}{not_methods}={}}{@not_methods} = @not_methods;
  # a role does itself
  $APPLIED_TO{$target} = { $target => undef };
  foreach my $hook (@ON_ROLE_CREATE) {
    $hook->($target);
  }
  return $me->_generate_subs($target);
}

sub _generate_subs {
  my ($me, $target) = (shift, shift);
  my %names = map {$_ => 1} @_ ? @_ : qw(before after around requires with);
  my %subs;
  foreach my $type (qw(before after around)) {
    next unless $names{$type};
    $subs{$type} = sub {
      push @{$INFO{$target}{modifiers}||=[]}, [ $type => @_ ];
      return;
    };
  }
  $subs{'requires'} = sub {
    push @{$INFO{$target}{requires}||=[]}, @_;
    return;
  } if $names{'requires'};
  $subs{'with'} = sub {
    $me->apply_roles_to_package($target, @_);
    return;
  } if $names{'with'};
  return \%subs;
}

1;
