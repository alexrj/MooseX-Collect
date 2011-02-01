package MooseX::Collect;
use strict;
use warnings;

our $VERSION = '0.90';

sub import {
    my ($class, %args) = @_;
    my $caller = caller();
    $class->setup_for($caller, \%args);
}

sub setup_for {
    my ($class, $pkg, $args) = @_;
    {
        no strict 'refs';
        *{ "${pkg}::collect" } = sub (@) { parse_collect($pkg, @_) };
    }
}

sub parse_collect {
    my ($package, @args) = @_;
    
    # validate method name
    my $method_name = shift @args
        or die "Can't call collect without providing a collector name";
    !ref $method_name
        or die "Collector name can only be a scalar";
    
    # we support two syntaxes
    my %init_args = ();
    if (@args == 1 && ref $args[0] eq 'CODE') {
        $init_args{collector} = $args[0];
    } else {
        @args % 2 and die "incorrect number of arguments passed to collect '$method_name'";
        %init_args = @args;
        
        # validate args
        !grep !/^(?:collector|provider|context|from|superclass_recurse|method_order)$/, 
            keys %init_args or die 'Invalid arguments supplied to collect';
        
        if (defined $init_args{context}) {
            $init_args{context} =~ /^(?:scalar|list)$/ or die "Bad context";
        }
        
        if (defined $init_args{from}) {
            $init_args{from} = [$init_args{from}] unless ref $init_args{from} eq 'ARRAY';
            !grep !/^(?:self|superclasses|roles)$/, @{$init_args{from}} 
                or die "Bad 'from' argument";
        }
        
        if (defined $init_args{method_order}) {
            $init_args{method_order} =~ /^(?:standard|top_down|reverse|bottom_up)$/ 
                or die "Bad method_order";
            $init_args{method_order} =~ s/top_down/standard/;
            $init_args{method_order} =~ s/bottom_up/reverse/;
        }
    }
    
    # set up defaults
    $init_args{collector} ||= sub { shift; @_ };
    $init_args{provider} ||= $method_name;
    $init_args{context} ||= 'list';
    $init_args{from} ||= [qw(self superclasses roles)];
    $init_args{superclass_recurse} = 1 if !defined $init_args{superclass_recurse};
    $init_args{method_order} ||= 'standard';
    
    my $meta = $package->meta;
    
    # if the caller package defines a provider method whose name
    # is equal to our accessor, we have to rename it in order to
    # install ours
    my $caller_provider;
    if ($method_name eq $init_args{provider} && $meta->has_method($init_args{provider})) {
        if (!$meta->get_method($init_args{provider})->isa('MooseX::Collect::Method')) {
            $caller_provider = $meta->remove_method($init_args{provider});
            $meta->add_method("_collect_$method_name" => $caller_provider);
        }
    }
    
    # a previous call to collect() may have renamed our provider
    $caller_provider ||= $meta->get_method("_collect_" . $init_args{provider});
    
    # generate the collection subroutine
    my $body = sub {
        my ($self, @args) = @_;
        
        # let's retrieve our superclasses
        my (undef, @superclasses) = map $_->meta, 
            grep $_->can('meta'), $meta->linearized_isa;
        @superclasses = ($superclasses[0]) if !$init_args{superclass_recurse};
        
        # let's find out which methods we need to call
        my @methods = ();
        foreach (@{$init_args{from}}) {
            if ($_ eq 'self') {
                unshift @methods, $caller_provider if $caller_provider;
            } else {
                my @metaclasses = ();
                push @metaclasses, @superclasses if $_ eq 'superclasses';
                push @metaclasses, grep !$_->isa('Moose::Meta::Role::Composite'), 
                    $meta->calculate_all_roles_with_inheritance if $_ eq 'roles';
                @metaclasses = reverse @metaclasses if $init_args{method_order} eq 'reverse';
                push @methods,
                    map $_->get_method($init_args{provider}),
                    grep $_->has_method($init_args{provider}),
                    @metaclasses;
            }
        }
        
        warn 'no methods found to collect' if scalar @methods == 0;
        
        # call methods and retrieve results
        my @items = map {
            $init_args{context} eq 'list' 
            ? ($_->execute(@args))
            : scalar $_->execute(@args)
        } @methods;
        
        # call user-provided subroutine
        $init_args{collector}->($self, @items);
    };
    
    # install the accessor method
    my $method = MooseX::Collect::Method->wrap(
        package_name => $package,
        name => $method_name,
        body => $body,
    );
    $meta->add_method($method_name => $method);
}

package MooseX::Collect::Method;
use base 'Class::MOP::Method';

1;
__END__

=pod

=head1 NAME

MooseX::Collect - provides method modifier for collecting method calls from roles and superclasses

=head1 SYNOPSIS

    package A;
    use Moose::Role;
    sub items () { qw/apple orange/ }
    
    package B;
    use Moose::Role;
    with 'A';
    sub items () { qw/watermelon/ }
    
    package C;
    use Moose::Role;
    sub items () { qw/banana/ }


    package Foo;
    use Moose;
    use MooseX::Collect;
    
    # easy syntax
    collect 'items';
    
    # explicit collector subroutine (allows you to process results)
    collect 'items' => {
        my $self = shift;
        return @_;
    };
    
    # explicit arguments for fine-grained configuration
    collect 'itemz' => (
        provider     => 'items',
        from         => [qw(self superclasses roles)],
        method_order => 'standard',
        context      => 'list',
        collector    => sub {
            my $self = shift;
            return @_;
        },
        superclass_recurse => 1,
    );
    
    # 'with' statements must be called after any 'collect'
    with qw(B C);


    my @items = $Foo->items;  # watermelon, apple, orange, banana


=head1 ABSTRACT

MooseX::Collect exports a "collect" method modifier that allows you to collect/compose the 
results of a method call dispatched to superclasses and/or roles of a given class.
Its interface is designed to be easy and similar to standard Moose method modifiers: nothing
special is required in the inherited classes, you just need to call the "collect" modifier in 
your final class in order to set up a method that will call all methods with the provided name
in the inherited classes and return you the results.

Any arguments passed to the newly created accessor will be passed to each method call.

=head1 EXPORTED FUNCTIONS

=over 4

=item B<collect $method_name>

=item B<collect $method_name =E<gt> sub {} >

=item B<collect $method_name =E<gt> ()>

This will install a method of a given C<$name> into the current class. You can pass a hash 
of options to the function. Available options are listed below.
As a shortcut, you can pass a coderef: it will be used as a I<collector> option (see below).

=over 4

=item I<provider =E<gt> $provider_method_name>

This option sets the name of the method that will be searched in the inherited classes. This
is useful if you want to use a different name for the local accessor. By default, the providers
method name is the same of the accessor name (i.e. the $method_name you passed to I<collect>).

=item I<from =E<gt> 'self' | 'superclass' | 'roles' | ARRAYREF>

This options accepts a string containing one of the above values or an arrayref containing 
one or more of them. Use it to specify which classes you want MooseX::Collect to search for
provider methods. The order is relevant. The value I<self> enables searching of the method
inside the current class too. The default value is I<self, superclass, roles>.

=item I<method_order =E<gt> 'standard' | 'reverse'>
=item I<method_order =E<gt> 'top_down' | 'bottom_up'>

This option lets you reverse the default method resolution order, which is I<standard>
(aliased as I<top_down>): derived classes will be called first. If you set this to
I<reverse> or I<bottom_up>, base classes will be called first.

=item I<superclass_recurse =E<gt> BOOL>

By setting this options to false, MooseX::Collect will not recurse into parent classes but will
only call the uppermost method available (i.e. the one that overrides any other with the same 
name implemented by parent classes). This option, which is false by default (allowing full 
recursion), does not affect searching in roles because they have no hierarchy.

=item I<context> =E<gt> 'scalar' | 'list'>

This arguments lets you set the Perl context to use when calling the provider methods. By 
default it's value is I<list>.

=item I<collector =E<gt> CODEREF>

If you want to customize or filter the collection results, you can provide a custom coderef.
It will receive the results in @_ and it's expected to return a list.

=back

=back

=head1 SEE ALSO

=over 4

=item C<Moose>

=item C<Moose::Role>

=item C<MooseX::ComposedBehavior>

=back

=head1 BUGS

Please report any bugs to C<bug-moosex-collect@rt.cpan.org>, or through the web
interface at L<https://rt.cpan.org/Public/Bug/Report.html?Queue=MooseX-Collect>.

=head1 AUTHOR

Alessandro Ranellucci <aar@cpan.org>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2011 by Alessandro Ranellucci.

This is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut