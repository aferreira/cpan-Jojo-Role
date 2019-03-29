
package Jojo::Role;

# ABSTRACT: Role::Tiny + lexical "with"
use 5.018;
use strict;
use warnings;
use utf8;
use feature      ();
use experimental ();

BEGIN {
  require Jojo::Role::Tiny;
  Jojo::Role::Tiny->VERSION('2.000006');
  our @ISA = qw(Jojo::Role::Tiny);
}

use Sub::Inject 0.3.0 ();

# Aliasing of Jojo::Role::Tiny symbols
BEGIN {
  *INFO = \%Jojo::Role::Tiny::INFO;
}

our %INFO;

our %EXPORT_TAGS;
our %EXPORT_GEN;

# Jojo::Role->apply_roles_to_package('Some::Package', qw(Some::Role +Other::Role));
sub apply_roles_to_package {
  my ($self, $target) = (shift, shift);
  return $self->Jojo::Role::Tiny::apply_roles_to_package($target,
    map { /^\+(.+)$/ ? "${target}::Role::$1" : $_ } @_);
}

# Jojo::Role->create_class_with_roles('Some::Base', qw(Some::Role1 +Role2));
sub create_class_with_roles {
  my ($self, $target) = (shift, shift);
  return $self->Jojo::Role::Tiny::create_class_with_roles($target,
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
    $me->make_role($target);
    $flag = '-role';
  }

  my @exports = @{$EXPORT_TAGS{$flag} // []};
  @_ = $me->_generate_subs($target, @exports);
  goto &Sub::Inject::sub_inject;
}

sub role_provider { $_[0] }

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
      my ($me, $target) = (shift->role_provider, shift);
      return sub {
        $me->apply_roles_to_package($target, @_);
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

L<Jojo::Role> works kind of like L<Role::Tiny> but C<with>, C<requires>,
C<before>, C<after> and C<around> are exported
as lexical subroutines.

This is a companion to L<Jojo::Base>.

L<Jojo::Role> may be used in two ways. First, to declare a role, which is done
with

    use Jojo::Base;
    use Jojo::Base -role;    # Longer version

Second, to compose one or more roles into a class, via

    use Jojo::Base -with;

=head1 IMPORTED -role SUBROUTINES

The C<-role> tag exports the following subroutines into the caller.

=head2 after

  after foo => sub { ... };

Declares an
L<< "after" |Class::Method::Modifiers/after method(s) => sub { ... } >>
modifier to be applied to the named method at composition time.

=head2 around

  around => sub { ... };

Declares an
L<< "around" |Class::Method::Modifiers/around method(s) => sub { ... } >>
modifier to be applied to the named method at composition time.

=head2 before

  before => sub { ... };

Declares a
L<< "before" |Class::Method::Modifiers/before method(s) => sub { ... } >>
modifier to be applied to the named method at composition time.

=head2 requires

  requires qw(foo bar);

Declares a list of methods that must be defined to compose the role.

=head2 with

  with 'Some::Role';

  with 'Some::Role1', 'Some::Role2';

Composes one or more roles into the current role.

=head1 IMPORTED -with SUBROUTINES

The C<-with> tag exports the following subroutine into the caller.
It is equivalent to using L<Role::Tiny::With>.

=head2 with

  with 'Some::Role1', 'Some::Role2';

Composes one or more roles into the current class.

=head1 METHODS

L<Jojo::Role> inherits all methods from L<Role::Tiny> and implements the
following new ones.

=head2 apply_roles_to_package

  Jojo::Role->apply_roles_to_package('Some::Package', qw(Some::Role +Other::Role));

=head2 create_class_with_roles

  Jojo::Role->create_class_with_roles('Some::Base', qw(Some::Role1 +Role2));

=head2 import

  Jojo::Role->import();
  Jojo::Role->import(-role);
  Jojo::Role->import(-with);

=head2 make_role

  Jojo::Role->make_role('Some::Package');

Promotes a given package to a role.
No subroutines are imported into C<'Some::Package'>.

=head1 CAVEATS

=over 4

=item *

L<Jojo::Role> requires perl 5.18 or newer

=item *

Because a lexical sub does not behave like a package import,
some code may need to be enclosed in blocks to avoid warnings like

    "state" subroutine &with masks earlier declaration in same scope at...

=back

=head1 SEE ALSO

L<Role::Tiny>, L<Jojo::Base>.

=head1 ACKNOWLEDGMENTS

Thanks to the authors of L<Role::Tiny>, which hold
the copyright over the original code.

=cut
