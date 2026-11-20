// A private application domain gives .NET Framework WinForms its own supported
// DPI configuration without changing powershell.exe.config or the watcher.
using System;
using System.Collections;
using System.Management.Automation;
using System.Management.Automation.Runspaces;

public sealed class QuotaUiDomain : MarshalByRefObject {
    public override object InitializeLifetimeService() { return null; }

    public int Run(string scriptPath, string parametersXml) {
        using (Runspace runspace = RunspaceFactory.CreateRunspace()) {
            runspace.ApartmentState = System.Threading.ApartmentState.STA;
            runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
            runspace.Open();
            using (PowerShell shell = PowerShell.Create()) {
                shell.Runspace = runspace;
                shell.AddCommand(scriptPath);
                object parameters = PSSerializer.Deserialize(parametersXml);
                if (parameters is PSObject) parameters = ((PSObject)parameters).BaseObject;
                foreach (DictionaryEntry entry in (IDictionary)parameters)
                    shell.AddParameter((string)entry.Key, entry.Value);
                shell.Streams.Information.DataAdded += delegate(object sender, DataAddedEventArgs e) {
                    Console.WriteLine(shell.Streams.Information[e.Index].MessageData);
                };
                try {
                    foreach (PSObject output in shell.Invoke()) Console.WriteLine(output);
                } catch (Exception error) {
                    Console.Error.WriteLine(error);
                    return 1;
                }
                if (shell.HadErrors) {
                    foreach (ErrorRecord error in shell.Streams.Error) Console.Error.WriteLine(error);
                    return 1;
                }
                object exitCode = runspace.SessionStateProxy.GetVariable("LASTEXITCODE");
                return exitCode is int ? (int)exitCode : 0;
            }
        }
    }
}
