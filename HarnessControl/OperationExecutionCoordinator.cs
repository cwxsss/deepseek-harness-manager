namespace HarnessControl;

internal static class OperationExecutionCoordinator
{
    public static async Task RunWithFinalizerAsync(Func<Task> operation, Func<Task> finalizer)
    {
        try
        {
            await operation();
        }
        finally
        {
            await finalizer();
        }
    }
}
