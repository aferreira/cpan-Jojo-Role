
package Jojo::Role;

use strict;
use warnings;

BEGIN {
  require Role::Tiny;
  Role::Tiny->VERSION('2.000001');
  our @ISA = qw(Role::Tiny);
}

use Sub::Inject 0.2.0 ();

package    # Just for the lexicals
  Role::Tiny;
our %INFO;
our %APPLIED_TO;
our @ON_ROLE_CREATE;

package Jojo::Role;

sub import {
  my $target = caller;
  my $me = shift;
  $_->import for qw(strict warnings);
  return if $me->is_role($target); # already exported into this package
  $INFO{$target}{is_role} = 1;
  # get symbol table reference
  my $stash = Role::Tiny::_getstash($target);
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
  @_ = ($me->_generate_subs($target));
  goto &Sub::Inject::sub_inject;
}

sub _generate_subs {
  my ($me, $target) = @_;
  my %subs;
  foreach my $type (qw(before after around)) {
    $subs{$type} = sub {
      push @{$INFO{$target}{modifiers}||=[]}, [ $type => @_ ];
      return;
    };
  }
  $subs{'requires'} = sub {
    push @{$INFO{$target}{requires}||=[]}, @_;
    return;
  };
  $subs{'with'} = sub {
    $me->apply_roles_to_package($target, @_);
    return;
  };
  return \%subs;
}

1;
