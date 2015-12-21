import click
import runpy

def print_version(ctx, param, value):
    if not value or ctx.resilient_parsing:
        return
    click.echo("Developed by Shahriyar Rzayev from Percona")
    click.echo("Link : https://github.com/Percona-QA/percona-qa")
    click.echo("Email: shahriyar.rzayev@percona.com")
    click.echo("Based on Percona TokuBackup: https://www.percona.com/doc/percona-server/5.6/tokudb/toku_backup.html")
    click.echo('MySQL-AutoTokuBackup Version 1.0')
    ctx.exit()


@click.command()
@click.option('--backup', is_flag=True, help="Take full backup using TokuBackup.")
@click.option('--version', is_flag=True, callback=print_version, expose_value=False, is_eager=True, help="Version information.")


def all_procedure(backup):
    if (not backup):
        print("ERROR: you must give an option, run with --help for available options")
    elif backup:
        runpy.run_module('backup.backup_calculation', run_name='__main__')



if __name__ == "__main__":
    all_procedure()