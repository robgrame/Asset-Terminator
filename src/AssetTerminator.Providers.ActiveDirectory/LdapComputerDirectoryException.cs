namespace AssetTerminator.Providers.ActiveDirectory;

public sealed class LdapComputerDirectoryException : Exception
{
    public LdapComputerDirectoryException(string message, bool transient, bool notFound, Exception? innerException = null)
        : base(message, innerException)
    {
        Transient = transient;
        NotFound = notFound;
    }

    public bool Transient { get; }
    public bool NotFound { get; }
}
