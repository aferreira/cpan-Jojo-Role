package Jojo::Role::Tiny;

sub _getglob { \*{$_[0]} }
sub _getstash { \%{"$_[0]::"} }

use strict;
use warnings;

our $VERSION = '2.000006';
$VERSION =~ tr/_//d;

our %INFO;
our %APPLIED_TO;
our %COMPOSED;
our %COMPOSITE_INFO;
our @ON_ROLE_CREATE;

# Module state workaround totally stolen from Zefram's Module::Runtime.

BEGIN {
  *_WORK_AROUND_BROKEN_MODULE_STATE = "$]" < 5.009 ? sub(){1} : sub(){0};
  *_WORK_AROUND_HINT_LEAKAGE
    = "$]" < 5.011 && !("$]" >= 5.009004 && "$]" < 5.010001)
      ? sub(){1} : sub(){0};
  *_MRO_MODULE = "$]" < 5.010 ? sub(){"MRO/Compat.pm"} : sub(){"mro.pm"};
}

sub croak {
  require Carp;
  no warnings 'redefine';
  *croak = \&Carp::croak;
  goto &Carp::croak;
}

sub Jojo::Role::Tiny::__GUARD__::DESTROY {
  delete $INC{$_[0]->[0]} if @{$_[0]};
}

sub _load_module {
  my ($module) = @_;
  (my $file = "$module.pm") =~ s{::}{/}g;
  return 1
    if $INC{$file};

  # can't just ->can('can') because a sub-package Foo::Bar::Baz
  # creates a 'Baz::' key in Foo::Bar's symbol table
  return 1
    if grep !/::\z/, keys %{_getstash($module)};
  my $guard = _WORK_AROUND_BROKEN_MODULE_STATE
    && bless([ $file ], 'Jojo::Role::Tiny::__GUARD__');
  local %^H if _WORK_AROUND_HINT_LEAKAGE;
  require $file;
  pop @$guard if _WORK_AROUND_BROKEN_MODULE_STATE;
  return 1;
}

sub import {
  my $target = caller;
  my $me = shift;
  strict->import;
  warnings->import;
  $me->_install_subs($target);
  $me->make_role($target);
}

sub make_role {
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
}

sub _install_subs {
  my ($me, $target) = @_;
  return if $me->is_role($target);
  # install before/after/around subs
  foreach my $type (qw(before after around)) {
    *{_getglob "${target}::${type}"} = sub {
      push @{$INFO{$target}{modifiers}||=[]}, [ $type => @_ ];
      return;
    };
  }
  *{_getglob "${target}::requires"} = sub {
    push @{$INFO{$target}{requires}||=[]}, @_;
    return;
  };
  *{_getglob "${target}::with"} = sub {
    $me->apply_roles_to_package($target, @_);
    return;
  };
}

sub role_application_steps {
  qw(_install_methods _check_requires _install_modifiers _copy_applied_list);
}

sub apply_single_role_to_package {
  my ($me, $to, $role) = @_;

  _load_module($role);

  croak "This is apply_role_to_package" if ref($to);
  croak "${role} is not a Role::Tiny" unless $me->is_role($role);

  foreach my $step ($me->role_application_steps) {
    $me->$step($to, $role);
  }
}

sub _copy_applied_list {
  my ($me, $to, $role) = @_;
  # copy our role list into the target's
  @{$APPLIED_TO{$to}||={}}{keys %{$APPLIED_TO{$role}}} = ();
}

sub apply_roles_to_object {
  my ($me, $object, @roles) = @_;
  croak "No roles supplied!" unless @roles;
  my $class = ref($object);
  # on perl < 5.8.9, magic isn't copied to all ref copies. bless the parameter
  # directly, so at least the variable passed to us will get any magic applied
  bless($_[1], $me->create_class_with_roles($class, @roles));
}

my $role_suffix = 'A000';
sub _composite_name {
  my ($me, $superclass, @roles) = @_;

  my $new_name = join(
    '__WITH__', $superclass, my $compose_name = join '__AND__', @roles
  );

  if (length($new_name) > 252) {
    $new_name = $COMPOSED{abbrev}{$new_name} ||= do {
      my $abbrev = substr $new_name, 0, 250 - length $role_suffix;
      $abbrev =~ s/(?<!:):$//;
      $abbrev.'__'.$role_suffix++;
    };
  }
  return wantarray ? ($new_name, $compose_name) : $new_name;
}

sub create_class_with_roles {
  my ($me, $superclass, @roles) = @_;

  croak "No roles supplied!" unless @roles;

  _load_module($superclass);
  {
    my %seen;
    if (my @dupes = grep 1 == $seen{$_}++, @roles) {
      croak "Duplicated roles: ".join(', ', @dupes);
    }
  }

  my ($new_name, $compose_name) = $me->_composite_name($superclass, @roles);

  return $new_name if $COMPOSED{class}{$new_name};

  foreach my $role (@roles) {
    _load_module($role);
    croak "${role} is not a Role::Tiny" unless $me->is_role($role);
  }

  require(_MRO_MODULE);

  my $composite_info = $me->_composite_info_for(@roles);
  my %conflicts = %{$composite_info->{conflicts}};
  if (keys %conflicts) {
    my $fail =
      join "\n",
        map {
          "Method name conflict for '$_' between roles "
          ."'".join("' and '", sort values %{$conflicts{$_}})."'"
          .", cannot apply these simultaneously to an object."
        } keys %conflicts;
    croak $fail;
  }

  my @composable = map $me->_composable_package_for($_), reverse @roles;

  # some methods may not exist in the role, but get generated by
  # _composable_package_for (Moose accessors via Moo).  filter out anything
  # provided by the composable packages, excluding the subs we generated to
  # make modifiers work.
  my @requires = grep {
    my $method = $_;
    !grep $_->can($method) && !$COMPOSED{role}{$_}{modifiers_only}{$method},
      @composable
  } @{$composite_info->{requires}};

  $me->_check_requires(
    $superclass, $compose_name, \@requires
  );

  *{_getglob("${new_name}::ISA")} = [ @composable, $superclass ];

  @{$APPLIED_TO{$new_name}||={}}{
    map keys %{$APPLIED_TO{$_}}, @roles
  } = ();

  $COMPOSED{class}{$new_name} = 1;
  return $new_name;
}

# preserved for compat, and apply_roles_to_package calls it to allow an
# updated Role::Tiny to use a non-updated Moo::Role

sub apply_role_to_package { shift->apply_single_role_to_package(@_) }

sub apply_roles_to_package {
  my ($me, $to, @roles) = @_;

  return $me->apply_role_to_package($to, $roles[0]) if @roles == 1;

  my %conflicts = %{$me->_composite_info_for(@roles)->{conflicts}};
  my @have = grep $to->can($_), keys %conflicts;
  delete @conflicts{@have};

  if (keys %conflicts) {
    my $fail =
      join "\n",
        map {
          "Due to a method name conflict between roles "
          ."'".join(' and ', sort values %{$conflicts{$_}})."'"
          .", the method '$_' must be implemented by '${to}'"
        } keys %conflicts;
    croak $fail;
  }

  # conflicting methods are supposed to be treated as required by the
  # composed role. we don't have an actual composed role, but because
  # we know the target class already provides them, we can instead
  # pretend that the roles don't do for the duration of application.
  my @role_methods = map $me->_concrete_methods_of($_), @roles;
  # separate loops, since local ..., delete ... for ...; creates a scope
  local @{$_}{@have} for @role_methods;
  delete @{$_}{@have} for @role_methods;

  # the if guard here is essential since otherwise we accidentally create
  # a $INFO for something that isn't a Role::Tiny (or Moo::Role) because
  # autovivification hates us and wants us to die()
  if ($INFO{$to}) {
    delete $INFO{$to}{methods}; # reset since we're about to add methods
  }

  # backcompat: allow subclasses to use apply_single_role_to_package
  # to apply changes.  set a local var so ours does nothing.
  our %BACKCOMPAT_HACK;
  if($me ne __PACKAGE__
      and exists $BACKCOMPAT_HACK{$me} ? $BACKCOMPAT_HACK{$me} :
      $BACKCOMPAT_HACK{$me} =
        $me->can('role_application_steps')
          == \&role_application_steps
        && $me->can('apply_single_role_to_package')
          != \&apply_single_role_to_package
  ) {
    foreach my $role (@roles) {
      $me->apply_single_role_to_package($to, $role);
    }
  }
  else {
    foreach my $step ($me->role_application_steps) {
      foreach my $role (@roles) {
        $me->$step($to, $role);
      }
    }
  }
  $APPLIED_TO{$to}{join('|',@roles)} = 1;
}

sub _composite_info_for {
  my ($me, @roles) = @_;
  $COMPOSITE_INFO{join('|', sort @roles)} ||= do {
    foreach my $role (@roles) {
      _load_module($role);
    }
    my %methods;
    foreach my $role (@roles) {
      my $this_methods = $me->_concrete_methods_of($role);
      $methods{$_}{$this_methods->{$_}} = $role for keys %$this_methods;
    }
    my %requires;
    @requires{map @{$INFO{$_}{requires}||[]}, @roles} = ();
    delete $requires{$_} for keys %methods;
    delete $methods{$_} for grep keys(%{$methods{$_}}) == 1, keys %methods;
    +{ conflicts => \%methods, requires => [keys %requires] }
  };
}

sub _composable_package_for {
  my ($me, $role) = @_;
  my $composed_name = 'Role::Tiny::_COMPOSABLE::'.$role;
  return $composed_name if $COMPOSED{role}{$composed_name};
  $me->_install_methods($composed_name, $role);
  my $base_name = $composed_name.'::_BASE';
  # force stash to exist so ->can doesn't complain
  _getstash($base_name);
  # Not using _getglob, since setting @ISA via the typeglob breaks
  # inheritance on 5.10.0 if the stash has previously been accessed an
  # then a method called on the class (in that order!), which
  # ->_install_methods (with the help of ->_install_does) ends up doing.
  { no strict 'refs'; @{"${composed_name}::ISA"} = ( $base_name ); }
  my $modifiers = $INFO{$role}{modifiers}||[];
  my @mod_base;
  my @modifiers = grep !$composed_name->can($_),
    do { my %h; @h{map @{$_}[1..$#$_-1], @$modifiers} = (); keys %h };
  foreach my $modified (@modifiers) {
    push @mod_base, "sub ${modified} { shift->next::method(\@_) }";
  }
  my $e;
  {
    local $@;
    eval(my $code = join "\n", "package ${base_name};", @mod_base);
    $e = "Evaling failed: $@\nTrying to eval:\n${code}" if $@;
  }
  die $e if $e;
  $me->_install_modifiers($composed_name, $role);
  $COMPOSED{role}{$composed_name} = {
    modifiers_only => { map { $_ => 1 } @modifiers },
  };
  return $composed_name;
}

sub _check_requires {
  my ($me, $to, $name, $requires) = @_;
  return unless my @requires = @{$requires||$INFO{$name}{requires}||[]};
  if (my @requires_fail = grep !$to->can($_), @requires) {
    # role -> role, add to requires, role -> class, error out
    if (my $to_info = $INFO{$to}) {
      push @{$to_info->{requires}||=[]}, @requires_fail;
    } else {
      croak "Can't apply ${name} to ${to} - missing ".join(', ', @requires_fail);
    }
  }
}

sub _concrete_methods_of {
  my ($me, $role) = @_;
  my $info = $INFO{$role};
  # grab role symbol table
  my $stash = _getstash($role);
  # reverse so our keys become the values (captured coderefs) in case
  # they got copied or re-used since
  my $not_methods = { reverse %{$info->{not_methods}||{}} };
  $info->{methods} ||= +{
    # grab all code entries that aren't in the not_methods list
    map {;
      no strict 'refs';
      my $code = exists &{"${role}::$_"} ? \&{"${role}::$_"} : undef;
      ( ! $code or exists $not_methods->{$code} ) ? () : ($_ => $code)
    } grep +(!ref($stash->{$_}) || ref($stash->{$_}) eq 'CODE'), keys %$stash
  };
}

sub methods_provided_by {
  my ($me, $role) = @_;
  croak "${role} is not a Role::Tiny" unless $me->is_role($role);
  (keys %{$me->_concrete_methods_of($role)}, @{$INFO{$role}->{requires}||[]});
}

sub _install_methods {
  my ($me, $to, $role) = @_;

  my $info = $INFO{$role};

  my $methods = $me->_concrete_methods_of($role);

  # grab target symbol table
  my $stash = _getstash($to);

  # determine already extant methods of target
  my %has_methods;
  @has_methods{grep
    +(ref($stash->{$_}) || *{$stash->{$_}}{CODE}),
    keys %$stash
  } = ();

  foreach my $i (grep !exists $has_methods{$_}, keys %$methods) {
    no warnings 'once';
    my $glob = _getglob "${to}::${i}";
    *$glob = $methods->{$i};

    # overloads using method names have the method stored in the scalar slot
    # and &overload::nil in the code slot.
    next
      unless $i =~ /^\(/
        && ((defined &overload::nil && $methods->{$i} == \&overload::nil)
            || (defined &overload::_nil && $methods->{$i} == \&overload::_nil));

    my $overload = ${ *{_getglob "${role}::${i}"}{SCALAR} };
    next
      unless defined $overload;

    *$glob = \$overload;
  }

  $me->_install_does($to);
}

sub _install_modifiers {
  my ($me, $to, $name) = @_;
  return unless my $modifiers = $INFO{$name}{modifiers};
  my $info = $INFO{$to};
  my $existing = ($info ? $info->{modifiers} : $COMPOSED{modifiers}{$to}) ||= [];
  my @modifiers = grep {
    my $modifier = $_;
    !grep $_ == $modifier, @$existing;
  } @{$modifiers||[]};
  push @$existing, @modifiers;

  if (!$info) {
    foreach my $modifier (@modifiers) {
      $me->_install_single_modifier($to, @$modifier);
    }
  }
}

my $vcheck_error;

sub _install_single_modifier {
  my ($me, @args) = @_;
  defined($vcheck_error) or $vcheck_error = do {
    local $@;
    eval {
      require Class::Method::Modifiers;
      Class::Method::Modifiers->VERSION(1.05);
      1;
    } ? 0 : $@;
  };
  $vcheck_error and die $vcheck_error;
  Class::Method::Modifiers::install_modifier(@args);
}

my $FALLBACK = sub { 0 };
sub _install_does {
  my ($me, $to) = @_;

  # only add does() method to classes
  return if $me->is_role($to);

  my $does = $me->can('does_role');
  # add does() only if they don't have one
  *{_getglob "${to}::does"} = $does unless $to->can('does');

  return
    if $to->can('DOES') and $to->can('DOES') != (UNIVERSAL->can('DOES') || 0);

  my $existing = $to->can('DOES') || $to->can('isa') || $FALLBACK;
  my $new_sub = sub {
    my ($proto, $role) = @_;
    $proto->$does($role) or $proto->$existing($role);
  };
  no warnings 'redefine';
  return *{_getglob "${to}::DOES"} = $new_sub;
}

sub does_role {
  my ($proto, $role) = @_;
  require(_MRO_MODULE);
  foreach my $class (@{mro::get_linear_isa(ref($proto)||$proto)}) {
    return 1 if exists $APPLIED_TO{$class}{$role};
  }
  return 0;
}

sub is_role {
  my ($me, $role) = @_;
  return !!($INFO{$role} && ($INFO{$role}{is_role} || $INFO{$role}{not_methods}));
}

1;

=encoding utf8

=head1 NAME

Jojo::Role::Tiny - A fork of Role::Tiny for Jojo nefarious purposes

=head1 DESCRIPTION

Internal to L<Jojo::Role> – don't use.

=head1 SEE ALSO

L<Role::Tiny>

=cut
