from functools import wraps
from telegram.message import Message
from telegram.update import Update
import logging
import os,subprocess
import telegram
from telegram.ext import Updater
from telegram.ext import CommandHandler, ConversationHandler
from telegram.ext.dispatcher import run_async
import jenkins
from settings import *
import json
import time
from urllib.parse import urlparse

logging.basicConfig(format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
                    level=logging.INFO)
logger = logging.getLogger(__name__)

token = BOT_TOKEN
bot = telegram.Bot(token=token)
print(bot.get_me())
updater = Updater(token=token, use_context=True, workers=8)
dispatcher = updater.dispatcher

server = jenkins.Jenkins(JENKINS_URL, username=JENKINS_USER, password=JENKINS_PASS)

def sendMessage(text: str, bot, update: Update):
    try:
        return bot.send_message(update.message.chat_id,
                            reply_to_message_id=update.message.message_id,
                            text=text, parse_mode='HTMl')
    except Exception as e:
        logger.error(str(e))

def editMessage(text: str, message: Message):
    try:
        bot.edit_message_text(text=text, message_id=message.message_id,
                              chat_id=message.chat.id,
                              parse_mode='HTMl')
    except Exception as e:
        logger.error(str(e))

def user_restricted(func):
    @wraps(func)
    def wrapped(update, context, *args, **kwargs):
        with open("restricted.json") as json_config_file:
            restricted = json.load(json_config_file)
        user_id = update.effective_user.id
        if str(user_id) not in restricted['user'].values():
            print(user_id, " is not in accessible users")
            print("WARNING: Unauthorized access denied for {}.".format(user_id))
            update.message.reply_text('You are not authorized to use this bot.')
            return  # quit function
        return func(update, context, *args, **kwargs)
    return wrapped

def start(update, context):
    sendMessage("Hello there!\n\nThis is an automation bot for StagOS Jenkins", context.bot, update)

@user_restricted
def build(update, context):
    inp = update.message.text
    jenkins_job_name = BUILD_JOB_NAME
    if len(inp.split(" ")) == 0:
        context.bot.send_message(chat_id=update.effective_chat.id, text="Device name not provided can't start the build without it")
        return
    m = inp.split(' ')
    device = {"device_codename": m[1]}
    pms = inp.split(' ')

    if len(pms)%2 == 1:
        return
    params={}
    for i in range(2, len(pms), 2):
        params[pms[i]] = pms[i+1]
    print(params)
    pm = dict(list(device.items()) + list(params.items()))
    k = server.build_job_url(jenkins_job_name, pm, token=None)
    l = urlparse(k)
    k = '''{}{}?{}'''.format(l.netloc, l.path, l.query)
    command = 'curl -X POST "https://{}:{}@{}"'.format(JENKINS_USER, JENKINS_TOKEN, k)
    os.system(command)
    sendMessage("Build triggered on jenkins.", context.bot, update)

def get_progress_bar(percent):
    whole = percent//10
    half = percent % 10
    progress = "[ " + "█"*whole
    if half:
        if half > 5:
            progress += "▓"
        else:
            progress += "░"
        half=1
    progress+= ' ]' + str(percent) + "%"
    return progress

def getPercent(server, job, number):
    j=''
    for line in reversed(server.get_build_console_output(job, number).split('\n')):
        if '[' in line and '%' in line:
             j = line.split('[',1)[1].lstrip().split(' ')[0]
             break
    return j

@user_restricted
def status(update, context):
    try:
        inp = update.message.text
        job = BUILD_JOB_NAME
        last=server.get_job_info(job)['lastCompletedBuild']['number']
        sum = last + 1
        device = (os.popen("cat /var/lib/jenkins/workspace/" + BUILD_JOB_NAME + "/current_device").read().rstrip("\n"))
        build_type = (os.popen("cat /var/lib/jenkins/workspace/" + BUILD_JOB_NAME + "/build_type").read().rstrip("\n"))
        msg=''
        j=getPercent(server, job, sum)
        command = '''curl -s "https://jenkins.stag-os.org/job/{}/{}/timestamps/?elapsed=mm:ss">ts'''.format(BUILD_JOB_NAME, sum)
        os.system(command)

        with open("ts", "r")as file:
            first_line = file.readline()
            for last_line in file:
                pass

        tim = last_line.strip("\n")
        m = tim.split(':')[0]
        s = tim.split(':')[1]
        status = server.get_build_info(job, sum)['result']
        if status == None:
            status='Building'
        exist = bool(j)
        if exist is False:
            sendMessage("Build hasn't started yet so wait my friend until it does.", context.bot, update)
        msg = '''
<b>Stag CI</b>

<b>Current Status:</b> {}

<b>{} | {}</b>

<b>Build Progress:</b>
{}

Elapsed Time: {} Minutes {} Seconds'''.format(status, device, build_type, get_progress_bar(int(j.strip('%'))), m, s)
        sent=sendMessage(msg, context.bot, update)
        i=0
        pristine_link, gapps_link, link_pristine_set, build_type_changed=[False, False, False, False]
        old_build_type=build_type
        while int(j.strip('%'))<=100:
            oldJ=int(j.strip('%'))
            j=getPercent(server, job, sum)
            if oldJ < int(j.strip('%')):
                if not build_type_changed:
                    build_type = (os.popen("cat /var/lib/jenkins/workspace/" + BUILD_JOB_NAME + "/build_type").read().rstrip("\n"))
                    if old_build_type != build_type:
                        build_type_changed=True
            time.sleep(5)
            command = '''curl -s "https://jenkins.stag-os.org/job/{}/{}/timestamps/?elapsed=mm:ss">ts'''.format(BUILD_JOB_NAME, sum)
            os.system(command)
            with open("ts", "r")as file:
                first_line = file.readline()
                for last_line in file:
                    pass

            tim = last_line.strip("\n")
            m = tim.split(':')[0]
            s = tim.split(':')[1]
            status = server.get_build_info(job, sum)['result']
            if status == None:
                status='Building'
            newMsg = '''
<b>Stag CI</b>

<b>Current Status:</b> {}

<b>{} | {}</b>

<b>Build Progress:</b>

{}

Elapsed Time: {} Minutes {} Seconds'''.format(status, device, build_type, get_progress_bar(int(j.strip('%'))), m,  s)
            if build_type_changed and not link_pristine_set:
                link_pristine_set=True
                with open('/var/lib/jenkins/workspace/' + BUILD_JOB_NAME + '/pristine_link') as f:
                    pristine_link=f.readlines()[0].strip('\n')

            if status== "SUCCESS":
                with open('/var/lib/jenkins/workspace/' + BUILD_JOB_NAME + '/gapps_link') as f:
                    gapps_link=f.readlines()[0].strip('\n')

            if pristine_link:
                newMsg+='\n\n<a href="{}">Pristine Link</a>'.format(pristine_link)

            if gapps_link:
                newMsg+='\n<a href="{}">Gapps Link</a>'.format(gapps_link)

            if newMsg==msg:
                continue
            editMessage(newMsg, sent)
            msg=newMsg
    except Exception as e:
        logger.error(str(e))
    return

@user_restricted
def release(update, context):
    inp = update.message.text
    jenkins_job_name = RELEASE_JOB_NAME
    if len(inp.split(" ")) == 0:
        context.bot.send_message(chat_id=update.effective_chat.id, text="Device name not given")
        return
    m = inp.split(' ')
    device = {"device": m[1]}
    pms = inp.split(' ')
    if len(pms)%2 == 1:
        return

    params={}
    for i in range(2, len(pms), 2):
        params[pms[i]] = pms[i+1]
    print(params)
    pm = dict(list(device.items()) + list(params.items()))
    k = server.build_job_url(jenkins_job_name, pm, token=None)
    l = urlparse(k)
    k = '''{}{}?{}'''.format(l.netloc, l.path, l.query)
    command = 'curl -X POST "https://{}:{}@{}"'.format(JENKINS_USER, JENKINS_TOKEN, k)
    os.system(command)
    sendMessage("Releasing build\n\nUploading builds...", context.bot, update)

@user_restricted
def stop(update, context):
    b = server.get_running_builds()
    job = b[0]['name']
    number = b[0]['number']
    server.stop_build(job, number)
    sendMessage("Stopped " + job + " on Jenkins.", context.bot, update)

def help(update, context):
    help_string = '''
Here are the available commands for Stag-CI bot

/start : Obv there for nothing

/build <i>jenkins_params</i> : To start a build remotely on jenkins

/release <i>device</i> : To release a build for devices.

/status : To check status of current build on jenkins.

/stop : to stop the ongoing build on jenkins.

'''
    sendMessage(help_string, context.bot, update)

functions = [build, status, release, stop, start, help]
for function in functions:
    handler = CommandHandler(function.__name__, function, run_async=True)
    dispatcher.add_handler(handler)

def main():
    updater.start_polling()
    updater.idle()

if __name__ == '__main__':
    main()