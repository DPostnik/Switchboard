#!/usr/bin/env python3
"""Same-user client for Switchboard's running scheduler; never edits its ledger."""
import argparse
import json
import os
from pathlib import Path
import sys
import time
import uuid

ROOT = Path.home() / 'Library/Application Support/Switchboard/schedule-control'
EPOCH = 978307200  # Foundation Date's reference epoch.


def message(ru, en):
    return ru + ' / ' + en


def send(payload):
    ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    request_id = str(uuid.uuid4()).upper()
    payload.update(version=1, id=request_id, expires=time.time() - EPOCH + 60)
    encoded = json.dumps(payload, ensure_ascii=False).encode('utf-8')
    if len(encoded) > 2_000_000:
        raise ValueError(message('Запрос слишком большой', 'Request is too large'))
    pending = ROOT / (request_id + '.request.json')
    temp = ROOT / (request_id + '.tmp')
    with os.fdopen(os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb') as f:
        f.write(encoded)
        f.flush()
        os.fsync(f.fileno())
    os.rename(temp, pending)
    print(message('ID запроса', 'Request ID') + ': ' + request_id, file=sys.stderr)
    deadline = time.monotonic() + 40
    while time.monotonic() < deadline:
        response = ROOT / (request_id + '.response.json')
        if response.exists():
            data = json.loads(response.read_text())
            if data.get('id') != request_id or data.get('version') != 1:
                raise RuntimeError(message('Некорректный ответ; не повторяй запрос', 'Invalid response; do not retry'))
            if data['status'] != 'completed':
                raise RuntimeError(data.get('message', data['status']))
            return data
        time.sleep(0.2)
    raise RuntimeError(message(
        'Ответ не получен. Не повторяй изменение: проверь status по этому ID. Непринятый запрос истекает через 60 секунд',
        'No reply. Do not repeat the mutation: check status with this ID. An unclaimed request expires after 60 seconds'))


def main():
    parser = argparse.ArgumentParser(description=message('Управление расписаниями открытого Switchboard', 'Control schedules in the running Switchboard'))
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('list', help=message('Прочитать задания', 'Read tasks'))
    sub.add_parser('catalog', help=message('Прочитать источники и проекты для импорта', 'Read import sources and projects'))
    importing = sub.add_parser('import', help=message('Импортировать постоянную рутину выключенной', 'Import an ongoing routine disabled'))
    importing.add_argument('--source-id', required=True)
    importing.add_argument('--project-id', required=True)
    importing.add_argument('--time-zone', required=True)
    importing.add_argument('--model', required=True)
    importing.add_argument('--effort', required=True)
    importing.add_argument('--prompt-file', type=Path)
    importing.add_argument('--recurring', required=True, action='store_true', help=message('Подтвердить постоянную рутину, не разовую задачу или пилот', 'Confirm an ongoing routine, not a one-time task or pilot'))
    create = sub.add_parser('create', help=message('Создать новое повторяющееся задание по поручению пользователя', 'Create a new recurring task at the user’s request'))
    create.add_argument('--name', required=True)
    create.add_argument('--project-id', required=True)
    create.add_argument('--prompt-file', required=True, type=Path)
    create.add_argument('--rule', required=True, help=message('Повторяющееся правило RRULE, например FREQ=DAILY;BYHOUR=8;BYMINUTE=0', 'Recurring RRULE, e.g. FREQ=DAILY;BYHOUR=8;BYMINUTE=0'))
    create.add_argument('--time-zone', required=True, help=message('Часовой пояс IANA', 'IANA time zone'))
    create.add_argument('--model', required=True)
    create.add_argument('--effort', required=True, choices=['none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra'])
    create.add_argument('--engine', default='codex', choices=['codex', 'claude'])
    create.add_argument('--enable', action='store_true', help=message('Включить сразу; иначе задание создаётся на паузе', 'Enable at once; otherwise the task is created paused'))
    status = sub.add_parser('status', help=message('Проверить запрос без повтора', 'Check a request without replay'))
    status.add_argument('request_id')
    update = sub.add_parser('update', help=message('Изменить существующее задание по поручению пользователя', 'Edit an existing task at the user’s request'))
    update.add_argument('--job-id', required=True)
    update.add_argument('--prompt-file', type=Path)
    update.add_argument('--rule', help=message('Новое повторяющееся правило RRULE, например FREQ=DAILY;BYHOUR=8,12;BYMINUTE=0', 'New recurring RRULE, e.g. FREQ=DAILY;BYHOUR=8,12;BYMINUTE=0'))
    update.add_argument('--time-zone', help=message('Часовой пояс IANA; по умолчанию текущий у задания', 'IANA time zone; defaults to the task’s current one'))
    update.add_argument('--model', help=message('Модель вместе с --effort', 'Model together with --effort'))
    update.add_argument('--effort', choices=['none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra'], help=message('Уровень рассуждения вместе с --model', 'Reasoning effort together with --model'))
    mode = update.add_mutually_exclusive_group()
    mode.add_argument('--enable', action='store_true')
    mode.add_argument('--pause', action='store_true')
    update.add_argument('--confirm-source-disabled', action='store_true', help=message('Подтвердить проверенную паузу оригинала', 'Confirm the verified original pause'))
    policy = update.add_mutually_exclusive_group()
    policy.add_argument('--accept-external-policy', action='store_true', help=message('Согласие пользователя на внешние правила Claude для этого задания', 'User consent to external Claude policy for this task'))
    policy.add_argument('--revoke-external-policy', action='store_true', help=message('Отозвать согласие на внешние правила Claude', 'Revoke consent to external Claude policy'))
    args = parser.parse_args()
    if args.command == 'status':
        key = str(uuid.UUID(args.request_id)).upper()
        response = ROOT / (key + '.response.json')
        if response.exists():
            print(response.read_text()); return
        state = 'uncertain' if (ROOT / (key + '.claimed.json')).exists() else 'pending-or-expired' if (ROOT / (key + '.request.json')).exists() else 'unknown'
        print(json.dumps({'id': key, 'status': state})); return
    if args.command == 'update' and ((args.model is None) != (args.effort is None)):
        parser.error(message('Укажи --model и --effort вместе', 'Specify --model and --effort together'))
    if args.command == 'update' and not (args.prompt_file or args.rule or args.time_zone or args.enable or args.pause or args.confirm_source_disabled or args.model
                                     or args.accept_external_policy or args.revoke_external_policy):
        parser.error(message('Не указано изменение', 'No change specified'))
    prompt = args.prompt_file.read_text() if args.command in ('update', 'import', 'create') and args.prompt_file else None
    if args.command == 'create':
        if not prompt.strip():
            parser.error(message('Файл с заданием пуст', 'The prompt file is empty'))
        created = dict(name=args.name, prompt=prompt, engine=args.engine, projectID=str(uuid.UUID(args.project_id)).upper(),
                       schedule={'rule': args.rule, 'timeZone': args.time_zone}, model=args.model, effort=args.effort)
        if args.enable:
            created['enabled'] = True
        reply = send({'operation': 'create', 'createRequest': created})
        print(json.dumps(reply, ensure_ascii=False, indent=2)); return
    reply = send({'operation': 'catalog' if args.command in ('catalog', 'import') else 'list'})
    if args.command == 'import':
        source = next((s for s in reply['catalog']['sources'] if s['definition']['id'] == args.source_id), None)
        if source is None:
            raise RuntimeError(message('Исходное задание недоступно', 'Source task unavailable'))
        if any(j.get('source') == 'codex:' + args.source_id for j in reply['jobs']):
            raise RuntimeError(message('Задание уже импортировано; используй update', 'Task already imported; use update'))
        imported = dict(sourceID=args.source_id, sourceDigest=source['digest'],
                        projectID=str(uuid.UUID(args.project_id)).upper(), timeZone=args.time_zone,
                        model=args.model, effort=args.effort, recurring=args.recurring)
        if prompt is not None:
            imported['prompt'] = prompt
        reply = send({'operation': 'import', 'importRequest': imported})
    if args.command == 'update':
        job_id = str(uuid.UUID(args.job_id)).upper()
        job = next((j for j in reply['jobs'] if j['id'].upper() == job_id), None)
        if job is None:
            raise RuntimeError(message('Задание не найдено', 'Task not found'))
        request = {'operation': 'update', 'expected': job}
        if args.model is not None:
            request.update(model=args.model, effort=args.effort)
        if prompt is not None:
            request['prompt'] = prompt
        if args.rule is not None or args.time_zone is not None:
            current = job['schedule']
            if current.get('once') is not None:
                raise RuntimeError(message('Разовое задание меняется только в редакторе', 'A one-time task can only be changed in the editor'))
            request['schedule'] = {'rule': args.rule if args.rule is not None else current['rule'],
                                   'timeZone': args.time_zone if args.time_zone is not None else current['timeZone']}
        if args.enable or args.pause:
            request['enabled'] = args.enable
        if args.confirm_source_disabled:
            request['confirmSourceDisabled'] = True
        if args.accept_external_policy or args.revoke_external_policy:
            request['acceptExternalPolicy'] = args.accept_external_policy
        reply = send(request)
    print(json.dumps(reply, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
