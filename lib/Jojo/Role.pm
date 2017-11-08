
package Jojo::Role;

# ABSTRACT: Role::Tiny + lexical "with"
use 5.018;
use strict;
use warnings;
use utf8;
use feature      ();
use experimental ();

BEGIN {
  require Role::Tiny;
  Role::Tiny->VERSION('2.000005');
  our @ISA = qw(Role::Tiny);
}

use Sub::Inject 0.3.0 ();

# Aliasing of Role::Tiny symbols
BEGIN {
  *INFO           = \%Role::Tiny::INFO;
  *APPLIED_TO     = \%Role::Tiny::APPLIED_TO;
  *COMPOSED       = \%Role::Tiny::COMPOSED;
  *COMPOSITE_INFO = \%Role::Tiny::COMPOSITE_INFO;
  *ON_ROLE_CREATE = \@Role::Tiny::ON_ROLE_CREATE;

  *_getstash = \&Role::Tiny::_getstash;
}

our %INFO;
our %APPLIED_TO;
our %COMPOSED;
our %COMPOSITE_INFO;
our @ON_ROLE_CREATE;

our %EXPORT_TAGS;
our %EXPORT_GEN;

# Jojo::Role->apply_roles_to_package('Some::Package', qw(Some::Role +Other::Role));
sub apply_roles_to_package {
  my ($self, $target) = (shift, shift);
  return $self->Role::Tiny::apply_roles_to_package($target,
    map { /^\+(.+)$/ ? "${target}::Role::$1" : $_ } @_);
}

# Jojo::Role->create_class_with_roles('Some::Base', qw(Some::Role1 +Role2));
sub create_class_with_roles {
  my ($self, $target) = (shift, shift);
  return $self->Role::Tiny::create_class_with_roles($target,
    map { /^\+(.+)$/ ? "${target}::Role::$1" : $_ } @_);
}

sub import {
  my $target = caller;
  my $me     = shift;

  # Jojo modules are strict!
  $_->import for qw(strict warnings utf8);
  feature->import(':5.18');
  experimental->import('lexical_subs');

  my $flag = shift;
  if (!$flag) {
    $me->_become_role($target);
    $flag = '-role';
  }

  my @exports = @{$EXPORT_TAGS{$flag} // []};
  @_ = $me->_generate_subs($target, @exports);
  goto &Sub::Inject::sub_inject;
}

sub role_provider { $_[0] }

sub _become_role {
  my ($me, $target) = @_;
  return if $me->is_role($target);    # already exported into this package
  $INFO{$target}{is_role} = 1;

  # get symbol table reference
  my $stash = _getstash($target);

  # grab all *non-constant* (stash slot is not a scalarref) subs present
  # in the symbol table and store their refaddrs (no need to forcibly
  # inflate constant subs into real subs) with a map to the coderefs in
  # case of copying or re-use
  my @not_methods
    = map +(ref $_ eq 'CODE' ? $_ : ref $_ ? () : *$_{CODE} || ()),
    values %$stash;
  @{$INFO{$target}{not_methods} = {}}{@not_methods} = @not_methods;

  # a role does itself
  $APPLIED_TO{$target} = {$target => undef};
  foreach my $hook (@ON_ROLE_CREATE) {
    $hook->($target);
  }
  return;
}

BEGIN {
  %EXPORT_TAGS = (    #
    -role => [qw(after around before requires with)],
    -with => [qw(with)],
  );

  %EXPORT_GEN = (
    requires => sub {
      my (undef, $target) = @_;
      return sub {
        push @{$INFO{$target}{requires} ||= []}, @_;
        return;
      };
    },
    with => sub {
      my ($me, $target) = @_;
      return sub {
        $me->role_provider->apply_roles_to_package($target, @_);
        return;
      };
    },
  );

  # before/after/around
  foreach my $type (qw(before after around)) {
    $EXPORT_GEN{$type} = sub {
      my (undef, $target) = @_;
      return sub {
        push @{$INFO{$target}{modifiers} ||= []}, [$type => @_];
        return;
      };
    };
  }
}

sub _generate_subs {
  my ($class, $target) = (shift, shift);
  return map { my $cb = $EXPORT_GEN{$_}; $_ => $class->$cb($target) } @_;
}

1;

=encoding utf8

=head1 SYNOPSIS

  package Some::Role {
    use Jojo::Role;    # requires perl 5.18+

    sub foo {...}
    sub bar {...}
    around baz => sub {...};
  }

  package Some::Class {
    use Jojo::Role -with;
    with 'Some::Role';

    # bar gets imported, but not foo
    sub foo {...}

    # baz is wrapped in the around modifier by Class::Method::Modifiers
    sub baz {...}
  }

=head1 DESCRIPTION

L<Jojo::Role> works kind of like L<Role::Tiny> but C<with>, C<require>,
C<before>, C<after> and C<around> are imported
as lexical subroutines.

This is a companion to L<Jojo::Base>.

=head1 CAVEATS

=over 4

=item *

L<Jojo::Role> requires perl 5.18 or newer

=item *

Because a lexical sub does not behave like a package import,
some code may need to be enclosed in blocks to avoid warnings like

    "state" subroutine &has masks earlier declaration in same scope at...

=back

=head1 SEE ALSO

L<Role::Tiny>, L<Jojo::Base>.

=head1 ACKNOWLEDGMENTS

Thanks to the authors of L<Role::Tiny>,
which hold the copyright over the original code.

=cut
