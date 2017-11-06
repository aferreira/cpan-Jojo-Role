
package Jojo::Role;

# ABSTRACT: Role::Tiny + lexical "with"
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

  # Jojo modules are strict!
  $_->import for qw(strict warnings utf8);
  feature->import(':5.10');

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

=encoding utf8

=head1 SYNOPSIS

 package Some::Role;

 use Jojo::Role;

 sub foo { ... }

 sub bar { ... }

 around baz => sub { ... };

 1;

elsewhere

 package Some::Class;

 use Jojo::Role -with;

 # bar gets imported, but not foo
 with 'Some::Role';

 sub foo { ... }

 # baz is wrapped in the around modifier by Class::Method::Modifiers
 sub baz { ... }

 1;

=head1 DESCRIPTION

L<Jojo::Role> works like L<Role::Tiny> but C<with>, C<require>,
C<before>, C<after> and C<around> are imported
as lexical subroutines.

This is a companion to L<Mojo::Bass>.

=cut
